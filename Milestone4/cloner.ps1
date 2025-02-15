Write-Host "Importing PowerCLI"
Import-Module VMware.PowerCLI

# Linked clone or full clone switch
Write-Host ""
Write-Host "This is a script for making clones in vCenter by Adam Hachem"
Write-Host ""
$switch = (Read-Host "Linked clone or full clone? (l/f)") 
if ($switch -eq "l") {
    $linked = $true
} else {
    $linked = $false
}

# Check for VIServer connection
Write-Host ""
if ($global:DefaultVIServer -eq $null) {
    Write-Host "No connection to vCenter. Please connect to vCenter." -ForegroundColor Yellow
    $vserver=(Read-Host "Enter the vCenter server name")
    Connect-VIServer($vserver)
}
Write-Host "Connected to $($global:DefaultVIServer.Name)" -ForegroundColor Green

Write-Host ""
Write-Host "VM List---" -ForegroundColor Green
Get-VM | Select-Object Name | ForEach-Object { Write-Host "`e[3m`t$($_.Name)`e[0m" -ForegroundColor Blue } 
Write-Host ""
$vm=Get-VM -Name (Read-Host "Enter the name of the VM to clone" )

Write-Host ""
Write-Host "Snapshot List for $vm---" -ForegroundColor Green
Get-Snapshot -VM $vm | Select-Object Name | ForEach-Object { Write-Host "`e[3m`t$($_.Name)`e[0m" -ForegroundColor Blue }
Write-Host ""
$snapshot = Get-Snapshot -VM $vm -Name (Read-Host "Enter the name of the snapshot to clone from")

Write-Host ""
Write-Host "ESXI Host List---" -ForegroundColor Green
Get-VMHost | Select-Object Name | ForEach-Object { Write-Host "`e[3m`t$($_.Name)`e[0m" -ForegroundColor Blue }
Write-Host "" 
$vmhost = Get-VMHost -Name (Read-Host "Enter the name of the host to clone to")

Write-Host ""
Write-Host "Datastore List---" -ForegroundColor Green
Get-Datastore | Select-Object Name | ForEach-Object { Write-Host "`e[3m`t$($_.Name)`e[0m" -ForegroundColor Blue }
Write-Host ""
$ds=Get-DataStore -Name (Read-Host "Enter the name of the datastore to clone to")

if (-not $linked) {
    $linkedname = "{0}.temp.linked" -f $vm.name
    # Create temp linked Clone
    $linkedvm = New-VM -LinkedClone -Name $linkedName -VM $vm -ReferenceSnapshot $snapshot -VMHost $vmhost -Datastore $ds
    $snapshot = New-Snapshot -Name “Base” -VM $linkedvm

    Write-Host ""
    $clonename = (Read-Host "Enter the name of the new full clone")
    $newvm = New-VM -Name $clonename -VM $linkedvm -VMHost $vmhost -Datastore $ds
    $snapshot = New-Snapshot -Name “Base” -VM $newvm

    Remove-VM -VM $linkedvm -DeletePermanently -Confirm:$false
    Write-Host ""
    Write-Host "Full clone '$newvm' created and snapshot taken" -ForegroundColor Green

} else {
    Write-Host ""
    $linkedname = (Read-Host "Enter the name of the new linked clone or leave blank to keep '.linked' default")
    if (-not $linkedname -eq "") {
        $linkedname = "{0}.{1}.linked" -f $linkedname, $vm.name
    } else {
        $linkedname = "{0}.linked" -f $vm.name
    }

    # Create temp linked Clone
    Write-Host ""
    $linkedvm = New-VM -LinkedClone -Name $linkedName -VM $vm -ReferenceSnapshot $snapshot -VMHost $vmhost -Datastore $ds
    $snapshot = New-Snapshot -Name “Base” -VM $linkedvm

    Write-Host "Linked clone '$linkedvm' created and snapshot taken" -ForegroundColor Green
}
