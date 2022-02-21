# Assumptions that you already have a working base vcenter and cluster setup with storage with 2019 OVA created
$vcenter = ""
$viUsername = ""
$viPassword = ""
$target_vmhost = ""
$target_datastore = ""
$target_network_ext = "VM Network"
$target_network_int = "VLC"
$target_jumpbox_Name = "vlc-jump"
$target_cpu = "8"
$target_mem = "16" # 16G

$windows_2019_template = "C:\VMware\Windows_2019_template.ova"

# DO NOT EDIT PAST HERE
Set-PowerCLIConfiguration -Scope AllUsers -ParticipateInCEIP:$false -confirm:$false | Out-Null
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
$viConnection = Connect-VIServer $vcenter -User $viUsername -Password $viPassword -WarningAction SilentlyContinue

Function My-Logger {
    param(
    [Parameter(Mandatory=$true)]
    [String]$message
    )

    $timeStamp = Get-Date -Format "MM-dd-yyyy_hh-mm-ss"

    Write-Host -NoNewline -ForegroundColor White "[$timestamp]"
    Write-Host -ForegroundColor Green " $message"
}
$StartTime = Get-Date
Clear-Host
My-Logger "Starting Deployment"

My-Logger "Deploy Jumpbox for VMware Lab Constructor"

$ovfconfig = Get-OvfConfiguration $windows_2019_template
$ovfconfig.NetworkMapping.VM_Network.value = $target_network_ext

$jumpvm = Import-VApp -Server $viConnection -Source $windows_2019_template -OvfConfiguration $ovfconfig -Name $target_jumpbox_Name -VMHost $target_vmhost -Datastore $target_datastore -DiskStorageFormat thin -Force # -Location $VApp
$jumpvm | Set-VM -NumCpu $target_cpu -CoresPerSocket $target_cpu -MemoryGB $target_mem -Server $viConnection -Confirm:$false
$pg_int = Get-VirtualPortGroup -name $target_network_int
$jumpvm | New-NetworkAdapter -Portgroup $pg_int -StartConnected -Type Vmxnet3 | Out-Null

My-Logger "Start the VM"
$jumpvm | Start-VM | Out-Null

do {
    $jumpvm = Get-VM -Name $target_jumpbox_Name
    Start-Sleep 30
} until($jumpvm.ExtensionData.Guest.ToolsRunningStatus -eq "guestToolsRunning") 

My-Logger "Starting Phase 1 Configuration"

# Define Guest Credentials.
$username="Administrator"
$password=ConvertTo-SecureString "VMware1!" -AsPlainText -Force
$GuestOSCred=New-Object -typename System.Management.Automation.PSCredential -argumentlist $username, $password

My-Logger "Setup Host"

# Need to enable "Internet Sharing" so the jump box can be also used to provide internet out

$setup_ics = @'
# Rename to jumpbox name
Rename-Computer -NewName $target_jumpbox_Name

# Enable Ethernet0 to be "public" and Ethernet1 as "private" to act as a NAT gateway
$InternetConnection = "Ethernet0"
$LocalConnection = "Ethernet1"
# Register the HNetCfg library (once)
regsvr32 /s hnetcfg.dll
# Create a NetSharingManager object
$netShare = New-Object -ComObject HNetCfg.HNetShare
# Find connections
$publicConnection = $netShare.EnumEveryConnection |? { $netShare.NetConnectionProps.Invoke($_).Name -eq $InternetConnection }
$privateConnection = $netShare.EnumEveryConnection |? { $netShare.NetConnectionProps.Invoke($_).Name -eq $LocalConnection }
# Get sharing configuration
$publicConfig = $netShare.INetSharingConfigurationForINetConnection.Invoke($publicConnection)
$privateConfig = $netShare.INetSharingConfigurationForINetConnection.Invoke($privateConnection)
$publicConfig.EnableSharing(0)
$privateConfig.EnableSharing(1)

# Configure the network interface addresses.
Disable-NetAdapterBinding -InterfaceAlias Ethernet0 -ComponentID ms_tcpip6
Disable-NetAdapterBinding -InterfaceAlias Ethernet1 -ComponentID ms_tcpip6
# Change below line to suit local network settings
netsh interface ip set address name="Ethernet0" static 10.0.1.101 255.255.255.0 10.0.1.1
Get-NetAdapter -Name Ethernet0 | Set-DnsClientServerAddress -ServerAddresses 192.168.0.3
netsh interface ip set address name="Ethernet1" static 10.0.0.220 255.255.255.0
Get-NetAdapter -Name Ethernet1 | Set-DnsClientServerAddress -ServerAddresses 10.0.0.221

# Ensure ICS works across reboots
New-ItemProperty -Path HKLM:\Software\Microsoft\Windows\CurrentVersion\SharedAccess -Name EnableRebootPersistConnection -Value 1 -PropertyType dword
Set-Service SharedAccess –startuptype automatic –passthru
Start-Service SharedAccess
NetSh Advfirewall set allprofiles state off
'@

Invoke-VMScript -ScriptType PowerShell -ScriptText $setup_ics -VM $jumpvm -GuestCredential $GuestOSCred | out-null

$setup_host = @'
mkdir -Force C:\VLC\
choco install notepadplusplus -y
'@

# TODO: Need to figure out how to add VLAN10 to Ethernet1 - Set-NetAdapter –Name "Ethernet1" -VlanID 10 doesn't work
# TODO: Need to install OVF 4.4 silently. 

Invoke-VMScript -ScriptText $setup_host -VM $jumpvm -GuestCredential $GuestOSCred | out-null

# Copy Software from C:\VLC (including CLoudBuilder) to VM \\server\c$\VLC\
$jump_ip = ($jumpvm | Get-View).Guest.Net.IpAddress[1]
New-PSDrive –Name “K” –PSProvider FileSystem –Root “\\$jump_ip\c$” –Credential $GuestOSCred | out-null
Copy-Item -Path 'C:\VLC\*' -Destination 'K:\VLC\'  -Force -Recurse | out-null
Remove-PSDrive -name "K" | out-null

$EndTime = Get-Date
$duration = [math]::Round((New-TimeSpan -Start $StartTime -End $EndTime).TotalMinutes,2)

My-Logger "Lab Deployment Complete!"
My-Logger "StartTime: $StartTime"
My-Logger "  EndTime: $EndTime"
My-Logger " Duration: $duration minutes"
