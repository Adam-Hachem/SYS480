# Function for importing PowerCLI if it is not already loaded, and logging in to vCenter
function Import-PowerCLI {
    # Check if PowerCLI is installed
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        Write-Error "PowerCLI is not installed. Please install it first."
        return
    }

    # Check if PowerCLI is already loaded
    $importTest = Get-Module -Name VMware.PowerCLI -All
    if (-not $importTest) {
        Write-Host "`nImporting PowerCLI`n"
        try {
            Import-Module VMware.PowerCLI -ErrorAction Stop | Out-Null
        } catch {
            Write-Error "Failed to import PowerCLI. Script terminated."
            Write-Error $_
        }
    }

    # Check for VIServer connection
    try {
        Get-VMHost -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "No connection to vCenter. Please connect to vCenter." -ForegroundColor Yellow
        do {
            $vserver = Read-Host "Enter the vCenter server name"
            if (Test-Connection $vserver -Count 1 -TcpPort 443) {
                $valid = $true
                Connect-VIServer -Server $vserver -ErrorAction Stop | Out-Null
                Write-Host "Connected to $($global:DefaultVIServer.Name)" -ForegroundColor Green
            } else {
                $valid = $false
                Write-Error "Server unreachable, please type URL again."
            }
        } while (-not $valid)
    }
}

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

# Function to create a new VM clone
function CloneMyVM([string]$ConfigFile) {
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

    # Import PowerCLI module
    Import-PowerCLI -ErrorAction Stop

    # Linked clone or full clone switch
    $switch = Read-Host "`nLinked clone or full clone? (l/f)"
    $linked = ($switch -eq "l")

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
    $adapters | Select-Object Name,NetworkName | Format-Table -AutoSize

    $netconfig = Read-Host "Do you want to change the network settings? (y/N)"
    if ($netconfig -match "^[Yy]") {
        Set-Network -VM $newvm -Quiet
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

# Function to create a new network, which creates a Virtual Switch and Portgroup
function New-Network([string]$Name,[string]$EsxiHost) {
    Import-PowerCLI -ErrorAction Stop

    # If no network name is provided, ask the user to enter one
    if (-not $Name) {
        # Ask user for network name
        $Name = Read-Host "`nEnter the name of the new network"
        # Validate that the network name is not empty or contains invalid characters
        if ($Name -match "[^a-zA-Z0-9_.-]") {
            Write-Error "Network name contains invalid characters. Only letters, numbers, underscores, hyphens, and periods are allowed."
            return
        }
        if (-not $Name) {
            Write-Error "Network name cannot be empty."
            return
        }
    }

    # Check if the network already exists
    if (Get-VirtualPortGroup -Name $Name -ErrorAction SilentlyContinue) {
        Write-Error "Network $Name already exists. Please choose a different name."
        return
    }

    # If no ESXi host is provided, ask the user to select one
    if (-not $EsxiHost) {
        # Get the name of the ESXi host from the user
        Write-Host "`nESXI Host List---" -ForegroundColor Green
        $EsxiHost = Get-UserSelection "Enter the number corresponding to the ESXi host" (Get-VMHost)
    } else {
        # Validate that the ESXi host exists
        try {
            $EsxiHost = Get-VMHost -Name $EsxiHost -ErrorAction Stop
        } catch {
            Write-Error "ESXi host '$EsxiHost' not found."
            return
        }
    }

    # Create the virtual switch
    try {
        $vs = New-VirtualSwitch -Name $Name -VMHost $EsxiHost -ErrorAction Stop
        Write-Host "`nVirtual switch '$($vs.Name)' created on host '$EsxiHost'" -ForegroundColor Green
    } catch {
        Write-Error "`nFailed to create virtual switch. Script terminated."
        Write-Error $_
        return
    }

    # Create the portgroup
    try {
        $pg = New-VirtualPortGroup -Name $Name -VirtualSwitch $vs -ErrorAction Stop
        Write-Host "Portgroup '$($pg.Name)' created on switch '$($vs.Name)'" -ForegroundColor Green
    } catch {
        Write-Error "Failed to create portgroup. Script terminated."
        Write-Error $_
        return
    }
}

# Function to get the IP and MAC address of each network adapter of a VM
function Get-IP([string]$VM) {
    # Import PowerCLI module
    Import-PowerCLI -ErrorAction Stop

    # If no VM name is provided, ask the user to select a VM
    if (-not $VM) {
        Write-Host "`nVM List---" -ForegroundColor Green
        $vmObject = Get-UserSelection "Enter the number corresponding to the VM" (Get-VM)
    } else {
        # Validate that the VM exists
        try {
            $vmObject = Get-VM -Name $VM -ErrorAction Stop
        } catch {
            Write-Error "VM '$vm' not found."
            return
        }
    }

    # Get the network adapters of the VM
    $adapters = $vmObject.ExtensionData.Guest.Net

    # Check if there are any network adapters
    if ($adapters.Count -eq 0) {
        Write-Host "No network adapters found for VM '$vmObject'" -ForegroundColor Red
        return
    }

    # Display IP and MAC addresses for each adapter
    Write-Host "`nIP and MAC addresses for VM '$vmObject'---" -ForegroundColor Green
    $adapters | ForEach-Object {
        $network = $_.Network
        $macAddress = $_.MacAddress
        # Filter for each type of address
        $ipv4Addresses = $_.IpAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }
        $ipv6Addresses = $_.IpAddress | Where-Object { $_ -match '^[0-9a-fA-F:]+$' }

        # Build a table
        [PSCustomObject]@{
            "Network"  = $network
            "MAC Address"   = $macAddress
            "IPv4 Address"  = if ($ipv4Addresses) { $ipv4Addresses -join ", " } else { "None" }
            "IPv6 Address"  = if ($ipv6Addresses) { $ipv6Addresses -join ", " } else { "None" }
        }
    } | Format-Table -AutoSize
}

# Function to start and stop VMs using Regex
function Set-VMPowerState {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RegexPattern,

        [Parameter(Mandatory = $true)]
        [ValidateSet("On", "Off")]
        [string]$Action,

        [Parameter(Mandatory = $false)]
        [switch]$ConfirmAction
    )
    Import-PowerCLI -ErrorAction Stop

    # Validate the regex pattern
    try {
        $null = [regex]::new($RegexPattern)
    } catch {
        Write-Error "Invalid regex pattern: $RegexPattern"
        return
    }

    # Get all VMs and filter by regex
    $VMsToManage = Get-VM | Where-Object {
        $_.Name -match $RegexPattern -and (
            ($Action -eq "On" -and $_.PowerState -ne "PoweredOn") -or
            ($Action -eq "Off" -and $_.PowerState -ne "PoweredOff")
        )
    }

    # If there are no matches that aren't already in the desired state
    if ($VMsToManage.Count -eq 0) {
        Write-Output "No matching VMs found that weren't $Action."
        return
    }

    Write-Output "The following VMs will be turned $Action."
    $VMsToManage | ForEach-Object { Write-Host "`t$_" -ForegroundColor Blue }

    if (-not $ConfirmAction) {
        $confirmation = Read-Host "`nDo you want to turn $Action these VMs? (y/n)"
        if ($confirmation -ne 'y') {
            Write-Output "Operation canceled."
            return
        }
    }

    # Start or Stop VMs
    try {
        foreach ($vm in $VMsToManage) {
            if ($Action -eq "On") {
                Start-VM -VM $vm -Confirm:$false
            } else {
                Stop-VM -VM $vm -Confirm:$false
            }
        }
        Write-Host "`nVM power $Action commands have been issued. Check VM status with 'Get-VM'" -ForegroundColor Green
    } catch {
        Write-Error "`nFailed to turn $Action VMs. Script terminated."
        Write-Error $_
    }
}

# Function to modify the network adapter settings of a VM
function Set-Network([string]$VM,[switch]$Quiet) {
    # Import PowerCLI module
    Import-PowerCLI -ErrorAction Stop
    # If no VM name is provided, ask the user to select a VM
    if (-not $VM) {
        Write-Host "`nVM List---" -ForegroundColor Green
        $VM = Get-UserSelection "Enter the number corresponding to the VM" (Get-VM)
    } else {
        # Validate that the VM exists
        try {
            $VM = Get-VM -Name $VM -ErrorAction Stop
        } catch {
            Write-Error "VM '$VM' not found."
            return
        }
    }

    # Show the current settings if quiet mode is not enabled
    if (-not $Quiet) {
        Write-Host "`nCurrent Network Adapter Settings---" -ForegroundColor Green
        $adapters = Get-NetworkAdapter -VM $VM
        $adapters | Select-Object Name,NetworkName | Format-Table -Autosize
        <#
        ForEach-Object {
            Write-Host "`e[3m`t$($_.Name):`t$($_.NetworkName)`e[0m" -ForegroundColor Blue
        }
        #>
    }

    foreach ($adapter in $adapters) {
        # Iterate through each of the adapters and ask what network it should be on
        Write-Host "`n$($adapter.Name): `tCurrent Network: $($adapter.NetworkName)" -ForegroundColor Cyan
        $selectedNetwork = Get-UserSelection "Enter the number corresponding to the desired network" (Get-VirtualNetwork)

        # Apply the user's choice
        Set-NetworkAdapter -NetworkAdapter $adapter -NetworkName $selectedNetwork.Name -Confirm:$false | Out-Null
        Write-Host "Adapter $($adapter.Name) connected to $($selectedNetwork.Name)" -ForegroundColor Green
    }
}
