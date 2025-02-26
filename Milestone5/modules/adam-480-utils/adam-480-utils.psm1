function CloneMyVM([string] $ConfigFile) {
    Write-Host "`nThis is a script for making clones in vCenter by Adam Hachem"
    
    if ($ConfigFile) {
        try {
            $conf = (Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json)
        } catch {
            Write-Error "Failed to read or fetch config file"
            Write-Error $_
        }
        Write-Host "`nUsing config from $ConfigFile"
    }

    Write-Host "`nImporting PowerCLI`n"
    try {
        Import-Module VMware.PowerCLI -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Failed to import PowerCLI. Script terminated."
        Write-Error $_
    }

    # Check for VIServer connection
    if ($null -eq $global:DefaultVIServer) {
        Write-Host "No connection to vCenter. Please connect to vCenter." -ForegroundColor Yellow
        $vserver = Read-Host "Enter the vCenter server name"
        Connect-VIServer -Server $vserver
    }
    Write-Host "Connected to $($global:DefaultVIServer.Name)" -ForegroundColor Green

    # Linked clone or full clone switch
    $switch = Read-Host "`nLinked clone or full clone? (l/f)"
    $linked = ($switch -eq "l")

    # Function for user selection with validation
    function Get-UserSelection {
        param (
            [string]$prompt,
            [array]$items
        )
        if ($items.Count -eq 0) {
            Write-Host "No options available." -ForegroundColor Red
            exit
        }
        for ($i = 0; $i -lt $items.Count; $i++) {
            Write-Host "`e[3m`t$($i):`t$($items[$i].Name)`e[0m" -ForegroundColor Blue
        }
        while ($true) {
            $choice = Read-Host $prompt
            if ($choice -match "^\d+$" -and [int]$choice -ge 0 -and [int]$choice -lt $items.Count) {
                return $items[$choice]
            }
            Write-Host "Invalid choice, please enter a valid number." -ForegroundColor Red
        }
    }

    if (-not $conf) {
        # Ask for the VM to clone
        Write-Host "`nVM List---" -ForegroundColor Green
        $vm = Get-UserSelection "Enter the number corresponding to the VM to clone" (Get-VM | Where-Object { $_.PowerState -eq "PoweredOff" })

        # Ask which snapshot to clone from
        Write-Host "`nSnapshot List for $vm---" -ForegroundColor Green
        $snapshot = Get-UserSelection "Enter the number corresponding to the snapshot to clone from" (Get-Snapshot -VM $vm)

        # Ask what ESXi host the new VM should live on
        Write-Host "`nESXI Host List---" -ForegroundColor Green
        $vmhost = Get-UserSelection "Enter the number corresponding to the host to clone to" (Get-VMHost)

        # Ask what datastore the new VM should be stored on
        Write-Host "`nDatastore List---" -ForegroundColor Green
        $datastore = Get-UserSelection "Enter the number corresponding to the datastore to clone to" (Get-Datastore)
    
    } else {
        # Load and validate settings
        try {
            $vm = Get-VM -Name $conf.vm -ErrorAction Stop
            $snapshot = Get-Snapshot -VM $vm -Name $conf.snapshot -ErrorAction Stop
            $vmhost = Get-VMHost -Name $conf.vmhost -ErrorAction Stop
            $datastore = Get-Datastore -Name $conf.datastore -ErrorAction Stop
        } catch {
            Write-Error "Config parameter invalid!"
            Write-Error $_ -ErrorAction Stop
        }
	Write-Host "`nConfig settings validated" -ForegroundColor Green
    }
    # Make a full clone
    if (-not $linked) {
        $linkedname = "{0}.temp.linked" -f $vm.Name
        # Create temp linked clone
        $linkedvm = New-VM -LinkedClone -Name $linkedName -VM $vm -ReferenceSnapshot $snapshot -VMHost $vmhost -Datastore $datastore
        $snapshot = New-Snapshot -Name "Base" -VM $linkedvm
        
        $clonename = Read-Host "`nEnter the name of the new full clone"
        $newvm = New-VM -Name $clonename -VM $linkedvm -VMHost $vmhost -Datastore $datastore
        
        # Delete temp linked clone
        Remove-VM -VM $linkedvm -DeletePermanently -Confirm:$false
        Write-Host "Full clone '$newvm' created" -ForegroundColor Green
    } else {
        $linkedname = Read-Host "`nEnter the name of the new linked clone or leave blank to keep '.linked' default"
        if (-not $linkedname -eq "") {
            $linkedname = "{0}.{1}.linked" -f $linkedname, $vm.Name
        } else {
            $linkedname = "{0}.linked" -f $vm.Name
        }
        $newvm = New-VM -LinkedClone -Name $linkedName -VM $vm -ReferenceSnapshot $snapshot -VMHost $vmhost -Datastore $datastore
        
        Write-Host "Linked clone '$newvm' created" -ForegroundColor Green
    }

    # Network Adapter Settings
    $adapters = Get-NetworkAdapter -VM $newvm

    # If there are no network adapters for the VM, ask if the user wants to create one
    if ($adapters.Count -eq 0) {
        Write-Host "No network adapters found." -ForegroundColor Red
        $createAdapter = Read-Host "Do you want to create a new network adapter? (y/N)"
        if ($createAdapter -match "^[Yy]") {
            $selectedNetwork = Get-UserSelection "Enter the number corresponding to the desired network" (Get-VirtualNetwork)
            New-NetworkAdapter -VM $newvm -NetworkName $selectedNetwork.Name -Type Vmxnet3 -Confirm:$false
            Write-Host "New adapter created and connected to $($selectedNetwork.Name)" -ForegroundColor Green
        } else {
            Write-Host "No network adapters available and none created." -ForegroundColor Cyan
        }
    }

    # Show the current settings
    Write-Host "`nCurrent Network Adapter Settings---" -ForegroundColor Green
    $adapters | Select-Object Name,NetworkName | ForEach-Object {
        Write-Host "`e[3m`t$($_.Name):`t$($_.NetworkName)`e[0m" -ForegroundColor Blue
    }

    $netconfig = Read-Host "Do you want to change the network settings? (y/N)"
    if ($netconfig -match "^[Yy]") {
        # Walk through each of the adapters and ask what network it should be on
        foreach ($adapter in (Get-NetworkAdapter -VM $newvm)) {
            Write-Host "`n$($adapter.Name): `tCurrent Network: $($adapter.NetworkName)" -ForegroundColor Cyan
            $selectedNetwork = Get-UserSelection "Enter the number corresponding to the desired network" (Get-VirtualNetwork)
            Set-NetworkAdapter -NetworkAdapter $adapter -NetworkName $selectedNetwork.Name -Confirm:$false | Out-Null
            Write-Host "Adapter $($adapter.Name) connected to $($selectedNetwork.Name)" -ForegroundColor Green
        }
    }
    Write-Host "`nConfiguration complete!" -ForegroundColor Green

    $snapshot = New-Snapshot -Name "Base" -VM $newvm
    Write-Host "`Snapshot automatically taken" -ForegroundColor Green

    # Ask if the user wants to power on the VM
    $powerOn = Read-Host "`nDo you want to power on the VM now? (y/N)"
    if ($powerOn -match "^[Yy]") {
        Start-VM -VM $newvm -Confirm:$false | Out-Null
        Write-Host "VM powered on." -ForegroundColor Green
    } else {
        Write-Host "VM remains powered off." -ForegroundColor Cyan
    }
}
