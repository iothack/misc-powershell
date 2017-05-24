<#
.SYNOPSIS
    Creates an Elevated (i.e. "Run As Administrator") PSSession for the current user in the current PowerShell Session.

.DESCRIPTION
    Using WSMan's CredSSP Authentication mechanism, this function creates a New PSSession via the New-PSSession
    cmdlet named "ElevatedPSSessionFor<UserName>". You can then run elevated commandsin the Elevated PSSession by
    either entering the Elevated PSSession via Enter-PSSession cmdlet or by using the Invoke-Command cmdlet with
    its -Session parameter.

    This function will NOT run in a PowerShell Session that was launched using "Run As Administrator".

    When used in a Non-Elevated PowerShell session, this function:

    1) Checks to make sure WinRM/WSMan is enabled and configured to allow CredSSP Authentication (if not then
    configuration changes are made)

    2) Checks the Local Group Policy Object...
        Computer Configuration -> Administrative Templates -> System -> Credentials Delegation -> Allow Delegating Fresh Credentials
    ...to make sure it is enabled and configured to allow connections via WSMAN/<LocalHostFQDN>

    3) Creates an Elevated PSSession using the New-PSSession cmdlet

    4) Outputs a PSCustomObject that contains two Properties:
    - ElevatedPSSession - Contains the object [PSSession]ElevatedPSSessionFor<UserName>
    - OriginalWSManAndRegistryStatus - Contains another PSCustomObject with the following Properties -
        OrigAllowFreshCredsProperties  : [A string the represents a registry path to the AllowFreshCredentials Key]
        OrigAllowFreshCredsValues      : [A string that represents the original Values/Properties of the AllowFreshCredentials Key if it existed before this function was run]
        Status                         : [Can be one of the following 3 strings - CredDelKey DNE/AllowFreshCreds DNE/AllowFreshCreds AlreadyExists]
        OrigWSMANConfigStatus          : [If WSMAN/WinRM was already enabled prior to this function being run, this value will be 'true']
        OrigWSMANServiceCredSSPSetting : [The value of WSMan:\localhost\Service\Auth\CredSSP prior to running this function - can be 'true' or 'false']
        OrigWSMANClientCredSSPSetting  : [The value of WSMan:\localhost\Client\Auth\CredSSP prior to running this function - can be 'true' or 'false']
        PropertyToRemove               : [If the AllowFreshCreds Registry Key does not contain a Property that has the value "WSMan/<LocalHostFQDN>" it will be added.
                                         PropertyToRemove will contain the Name of this added Registry Property, which, for the AllowFreshCredentials Key, is a number.]

.NOTES
    Recommend assigning this function to a variable when it is used so that it can be referenced in the companion
    function Remove-SudoSession. If you do NOT assign a variable to this function when it is used, you can always
    reference this function's PSCustomObject output by calling $global:NewSessionAndOriginalStatus, which is a
    Global Scope variable created when this function is run. $global:NewSessionAndOriginalStatus.OriginalWSManAndRegistryStatus
    can be used for Remove-SudoSession's -OriginalConfigInfo parameter, and $global:NewSessionAndOriginalStatus.ElevatedPSSesion
    can be used for Remove-SudoSession's -SessionToRemove parameter.

.PARAMETER UserName
    This is a string that represents a UserName with Administrator privileges. Defaults to current user.

    This parameter is mandatory if you do NOT use the -Credentials parameter.

.PARAMETER Password
    This can be either a plaintext string or a secure string that represents the password for the -UserName.

    This parameter is mandatory if you do NOT use the -Credentials parameter.

.PARAMETER Credentials
    This is a System.Management.Automation.PSCredential object used to create an elevated PSSession.

.EXAMPLE
    PS C:\Users\zeroadmin> New-SudoSession -UserName zeroadmin -Credentials $MyCreds

    ElevatedPSSession                      OriginalWSManAndRegistryStatus
    -----------------                      ------------------------------
    [PSSession]ElevatedSessionForzeroadmin @{OrigAllowFreshCredsProperties=HKEY_LOCAL_MACHINE\Software\Policies\Microsoft...

    PS C:\Users\zeroadmin> Get-PSSession

     Id Name            ComputerName    ComputerType    State         ConfigurationName     Availability
     -- ----            ------------    ------------    -----         -----------------     ------------
      1 ElevatedSess... localhost       RemoteMachine   Opened        Microsoft.PowerShell     Available

    PS C:\Users\zeroadmin> Enter-PSSession -Name ElevatedSessionForzeroadmin
    [localhost]: PS C:\Users\zeroadmin\Documents> 

.EXAMPLE
    PS C:\Users\zeroadmin> $MyElevatedSession = New-SudoSession -UserName zeroadmin -Credentials $MyCreds
    PS C:\Users\zeroadmin> Get-PSSession

     Id Name            ComputerName    ComputerType    State         ConfigurationName     Availability
     -- ----            ------------    ------------    -----         -----------------     ------------
      1 ElevatedSess... localhost       RemoteMachine   Opened        Microsoft.PowerShell     Available

    PS C:\Users\zeroadmin> Invoke-Command -Session $MyElevatedSession.ElevatedPSSession -Scriptblock {Install-Package Nuget.CommandLine -Source chocolatey}

.OUTPUTS
    See DESCRIPTION and NOTES sections

#>
function New-SudoSession {
    [CmdletBinding(DefaultParameterSetName='Supply UserName and Password')]
    Param(
        [Parameter(
            Mandatory=$False,
            ParameterSetName='Supply UserName and Password'
        )]
        [string]$UserName = $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name -split "\\")[-1],

        [Parameter(
            Mandatory=$False,
            ParameterSetName='Supply UserName and Password'
        )]
        $Password,

        [Parameter(
            Mandatory=$False,
            ParameterSetName='Supply Credentials'
        )]
        [System.Management.Automation.PSCredential]$Credentials

    )

    ##### BEGIN Native Helper Functions #####

    function Check-Elevation {
        [System.Security.Principal.WindowsPrincipal]$currentPrincipal = `
            New-Object System.Security.Principal.WindowsPrincipal(
                [System.Security.Principal.WindowsIdentity]::GetCurrent());

        [System.Security.Principal.WindowsBuiltInRole]$administratorsRole = `
            [System.Security.Principal.WindowsBuiltInRole]::Administrator;

        if($currentPrincipal.IsInRole($administratorsRole))
        {
            return $true;
        }
        else
        {
            return $false;
        }
    }

    if (Check-Elevation) {
        Write-Verbose "The current PowerShell Session is already being run with elevated permissions. There is no reason to use the Start-SudoSession function. Halting!"
        Write-Error "The current PowerShell Session is already being run with elevated permissions. There is no reason to use the Start-SudoSession function. Halting!"
        $global:FunctionResult = "1"
        return
    }

    ##### END Native Helper Functions #####

    ##### BEGIN Variable/Parameter Transforms and PreRun Prep #####

    if ($UserName -and !$Password -and !$Credentials) {
        $Password = Read-Host -Prompt "Please enter the password for $UserName" -AsSecureString
    }

    if ($UserName -and $Password) {
        if ($Password.GetType().FullName -eq "System.String") {
            $Password = ConvertTo-SecureString $Password -AsPlainText -Force
        }
        $Credentials = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $UserName, $Password
    }

    $Domain = $(Get-CimInstance -ClassName Win32_ComputerSystem).Domain
    $LocalHostFQDN = "$env:ComputerName.$Domain"

    ##### END Variable/Parameter Transforms and PreRunPrep #####

    ##### BEGIN Main Body #####

    $CredDelRegLocation = "HKLM:\Software\Policies\Microsoft\Windows\CredentialsDelegation"
    $CredDelRegLocationParent = $CredDelRegLocation | Split-Path -Parent
    $AllowFreshValue = "WSMAN/$LocalHostFQDN"
    $tmpFileXmlPrep = [IO.Path]::GetTempFileName()
    $UpdatedtmpFileXmlName = $tmpFileXmlPrep -replace "\.tmp",".xml"
    $tmpFileXml = $UpdatedtmpFileXmlName
    $TranscriptPath = "$HOME\Open-SudoSession_Transcript_$UserName_$(Get-Date -Format MM-dd-yyy_hhmm_tt).txt"

    $WSManGPOTempConfig = @"
-noprofile -WindowStyle Hidden -Command "Start-Transcript -Path $TranscriptPath -Append
try {`$CurrentAllowFreshCredsProperties = Get-ChildItem -Path $CredDelRegLocation | ? {`$_.PSChildName -eq 'AllowFreshCredentials'}} catch {}
try {`$CurrentAllowFreshCredsValues = foreach (`$propNum in `$CurrentAllowFreshCredsProperties) {`$(Get-ItemProperty -Path '$CredDelRegLocation\AllowFreshCredentials').`$propNum}} catch {}

if (!`$(Test-WSMan)) {`$WinRMConfigured = 'false'; winrm quickconfig /force; Start-Sleep -Seconds 5} else {`$WinRMConfigured = 'true'}
try {`$CredSSPServiceSetting = `$(Get-ChildItem WSMan:\localhost\Service\Auth\CredSSP).Value} catch {}
try {`$CredSSPClientSetting = `$(Get-ChildItem WSMan:\localhost\Client\Auth\CredSSP).Value} catch {}
if (`$CredSSPServiceSetting -eq 'false') {Enable-WSManCredSSP -Role Server -Force}
if (`$CredSSPClientSetting -eq 'false') {Enable-WSManCredSSP -DelegateComputer localhost -Role Client -Force}

if (!`$(Test-Path $CredDelRegLocation)) {`$Status = 'CredDelKey DNE'}
if (`$(Test-Path $CredDelRegLocation) -and !`$(Test-Path $CredDelRegLocation\AllowFreshCredentials)) {`$Status = 'AllowFreshCreds DNE'}
if (`$(Test-Path $CredDelRegLocation) -and `$(Test-Path $CredDelRegLocation\AllowFreshCredentials)) {`$Status = 'AllowFreshCreds AlreadyExists'}

if (!`$(Test-Path $CredDelRegLocation)) {New-Item -Path $CredDelRegLocation}
if (`$(Test-Path $CredDelRegLocation) -and !`$(Test-Path $CredDelRegLocation\AllowFreshCredentials)) {New-Item -Path $CredDelRegLocation\AllowFreshCredentials}

if (`$CurrentAllowFreshCredsValues -notcontains '$AllowFreshValue') {Set-ItemProperty -Path $CredDelRegLocation -Name ConcatenateDefaults_AllowFresh -Value `$(`$CurrentAllowFreshCredsProperties.Count+1) -Type DWord; Start-Sleep -Seconds 2; Set-ItemProperty -Path $CredDelRegLocation\AllowFreshCredentials -Name `$(`$CurrentAllowFreshCredsProperties.Count+1) -Value '$AllowFreshValue' -Type String}
New-Variable -Name 'OrigAllowFreshCredsState' -Value `$([pscustomobject][ordered]@{OrigAllowFreshCredsProperties = `$CurrentAllowFreshCredsProperties; OrigAllowFreshCredsValues = `$CurrentAllowFreshCredsValues; Status = `$Status; OrigWSMANConfigStatus = `$WinRMConfigured; OrigWSMANServiceCredSSPSetting = `$CredSSPServiceSetting; OrigWSMANClientCredSSPSetting = `$CredSSPClientSetting; PropertyToRemove = `$(`$CurrentAllowFreshCredsProperties.Count+1)})
`$(Get-Variable -Name 'OrigAllowFreshCredsState' -ValueOnly) | Export-CliXml -Path $tmpFileXml
exit"
"@
    $WSManGPOTempConfigFinal = $WSManGPOTempConfig -replace "`n","; "

    # IMPORTANT NOTE: You CANNOT use the RunAs Verb if UseShellExecute is $false, and you CANNOT use
    # RedirectStandardError or RedirectStandardOutput if UseShellExecute is $true, so we have to write
    # output to a file temporarily
    $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
    $ProcessInfo.FileName = "powershell.exe"
    $ProcessInfo.RedirectStandardError = $false
    $ProcessInfo.RedirectStandardOutput = $false
    $ProcessInfo.UseShellExecute = $true
    $ProcessInfo.Arguments = $WSManGPOTempConfigFinal
    $ProcessInfo.Verb = "RunAs"
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $ProcessInfo
    $Process.Start() | Out-Null
    $Process.WaitForExit()
    $WSManAndRegStatus = Import-CliXML $tmpFileXml

    $ElevatedPSSession = New-PSSession -Name "ElevatedSessionFor$UserName" -Authentication CredSSP -Credential $Credentials

    New-Variable -Name "NewSessionAndOriginalStatus" -Scope Global -Value $(
        [pscustomobject][ordered]@{
            ElevatedPSSession   = $ElevatedPSSession
            OriginalWSManAndRegistryStatus   = $WSManAndRegStatus
        }
    ) -Force
    
    $(Get-Variable -Name "NewSessionAndOriginalStatus" -ValueOnly)

    # Cleanup 
    Remove-Item $tmpFileXml

    ##### END Main Body #####

}












# SIG # Begin signature block
# MIIMLAYJKoZIhvcNAQcCoIIMHTCCDBkCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQURN98JRJth7wbl17uiLH7Cui5
# S+qgggmhMIID/jCCAuagAwIBAgITawAAAAQpgJFit9ZYVQAAAAAABDANBgkqhkiG
# 9w0BAQsFADAwMQwwCgYDVQQGEwNMQUIxDTALBgNVBAoTBFpFUk8xETAPBgNVBAMT
# CFplcm9EQzAxMB4XDTE1MDkwOTA5NTAyNFoXDTE3MDkwOTEwMDAyNFowPTETMBEG
# CgmSJomT8ixkARkWA0xBQjEUMBIGCgmSJomT8ixkARkWBFpFUk8xEDAOBgNVBAMT
# B1plcm9TQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCmRIzy6nwK
# uqvhoz297kYdDXs2Wom5QCxzN9KiqAW0VaVTo1eW1ZbwZo13Qxe+6qsIJV2uUuu/
# 3jNG1YRGrZSHuwheau17K9C/RZsuzKu93O02d7zv2mfBfGMJaJx8EM4EQ8rfn9E+
# yzLsh65bWmLlbH5OVA0943qNAAJKwrgY9cpfDhOWiYLirAnMgzhQd3+DGl7X79aJ
# h7GdVJQ/qEZ6j0/9bTc7ubvLMcJhJCnBZaFyXmoGfoOO6HW1GcuEUwIq67hT1rI3
# oPx6GtFfhCqyevYtFJ0Typ40Ng7U73F2hQfsW+VPnbRJI4wSgigCHFaaw38bG4MH
# Nr0yJDM0G8XhAgMBAAGjggECMIH/MBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQW
# BBQ4uUFq5iV2t7PneWtOJALUX3gTcTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMA
# QTAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBR2
# lbqmEvZFA0XsBkGBBXi2Cvs4TTAxBgNVHR8EKjAoMCagJKAihiBodHRwOi8vcGtp
# L2NlcnRkYXRhL1plcm9EQzAxLmNybDA8BggrBgEFBQcBAQQwMC4wLAYIKwYBBQUH
# MAKGIGh0dHA6Ly9wa2kvY2VydGRhdGEvWmVyb0RDMDEuY3J0MA0GCSqGSIb3DQEB
# CwUAA4IBAQAUFYmOmjvbp3goa3y95eKMDVxA6xdwhf6GrIZoAg0LM+9f8zQOhEK9
# I7n1WbUocOVAoP7OnZZKB+Cx6y6Ek5Q8PeezoWm5oPg9XUniy5bFPyl0CqSaNWUZ
# /zC1BE4HBFF55YM0724nBtNYUMJ93oW/UxsWL701c3ZuyxBhrxtlk9TYIttyuGJI
# JtbuFlco7veXEPfHibzE+JYc1MoGF/whz6l7bC8XbgyDprU1JS538gbgPBir4RPw
# dFydubWuhaVzRlU3wedYMsZ4iejV2xsf8MHF/EHyc/Ft0UnvcxBqD0sQQVkOS82X
# +IByWP0uDQ2zOA1L032uFHHA65Bt32w8MIIFmzCCBIOgAwIBAgITWAAAADw2o858
# ZSLnRQAAAAAAPDANBgkqhkiG9w0BAQsFADA9MRMwEQYKCZImiZPyLGQBGRYDTEFC
# MRQwEgYKCZImiZPyLGQBGRYEWkVSTzEQMA4GA1UEAxMHWmVyb1NDQTAeFw0xNTEw
# MjcxMzM1MDFaFw0xNzA5MDkxMDAwMjRaMD4xCzAJBgNVBAYTAlVTMQswCQYDVQQI
# EwJWQTEPMA0GA1UEBxMGTWNMZWFuMREwDwYDVQQDEwhaZXJvQ29kZTCCASIwDQYJ
# KoZIhvcNAQEBBQADggEPADCCAQoCggEBAJ8LM3f3308MLwBHi99dvOQqGsLeC11p
# usrqMgmEgv9FHsYv+IIrW/2/QyBXVbAaQAt96Tod/CtHsz77L3F0SLuQjIFNb522
# sSPAfDoDpsrUnZYVB/PTGNDsAs1SZhI1kTKIjf5xShrWxo0EbDG5+pnu5QHu+EY6
# irn6C1FHhOilCcwInmNt78Wbm3UcXtoxjeUl+HlrAOxG130MmZYWNvJ71jfsb6lS
# FFE6VXqJ6/V78LIoEg5lWkuNc+XpbYk47Zog+pYvJf7zOric5VpnKMK8EdJj6Dze
# 4tJ51tDoo7pYDEUJMfFMwNOO1Ij4nL7WAz6bO59suqf5cxQGd5KDJ1ECAwEAAaOC
# ApEwggKNMA4GA1UdDwEB/wQEAwIHgDA9BgkrBgEEAYI3FQcEMDAuBiYrBgEEAYI3
# FQiDuPQ/hJvyeYPxjziDsLcyhtHNeIEnofPMH4/ZVQIBZAIBBTAdBgNVHQ4EFgQU
# a5b4DOy+EUyy2ILzpUFMmuyew40wHwYDVR0jBBgwFoAUOLlBauYldrez53lrTiQC
# 1F94E3EwgeMGA1UdHwSB2zCB2DCB1aCB0qCBz4aBq2xkYXA6Ly8vQ049WmVyb1ND
# QSxDTj1aZXJvU0NBLENOPUNEUCxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxD
# Tj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9uLERDPXplcm8sREM9bGFiP2NlcnRp
# ZmljYXRlUmV2b2NhdGlvbkxpc3Q/YmFzZT9vYmplY3RDbGFzcz1jUkxEaXN0cmli
# dXRpb25Qb2ludIYfaHR0cDovL3BraS9jZXJ0ZGF0YS9aZXJvU0NBLmNybDCB4wYI
# KwYBBQUHAQEEgdYwgdMwgaMGCCsGAQUFBzAChoGWbGRhcDovLy9DTj1aZXJvU0NB
# LENOPUFJQSxDTj1QdWJsaWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxD
# Tj1Db25maWd1cmF0aW9uLERDPXplcm8sREM9bGFiP2NBQ2VydGlmaWNhdGU/YmFz
# ZT9vYmplY3RDbGFzcz1jZXJ0aWZpY2F0aW9uQXV0aG9yaXR5MCsGCCsGAQUFBzAC
# hh9odHRwOi8vcGtpL2NlcnRkYXRhL1plcm9TQ0EuY3J0MBMGA1UdJQQMMAoGCCsG
# AQUFBwMDMBsGCSsGAQQBgjcVCgQOMAwwCgYIKwYBBQUHAwMwDQYJKoZIhvcNAQEL
# BQADggEBACbc1NDl3NTMuqFwTFd8NHHCsSudkVhuroySobzUaFJN2XHbdDkzquFF
# 6f7KFWjqR3VN7RAi8arW8zESCKovPolltpp3Qu58v59qZLhbXnQmgelpA620bP75
# zv8xVxB9/xmmpOHNkM6qsye4IJur/JwhoHLGqCRwU2hxP1pu62NUK2vd/Ibm8c6w
# PZoB0BcC7SETNB8x2uKzJ2MyAIuyN0Uy/mGDeLyz9cSboKoG6aQibnjCnGAVOVn6
# J7bvYWJsGu7HukMoTAIqC6oMGerNakhOCgrhU7m+cERPkTcADVH/PWhy+FJWd2px
# ViKcyzWQSyX93PcOj2SsHvi7vEAfCGcxggH1MIIB8QIBATBUMD0xEzARBgoJkiaJ
# k/IsZAEZFgNMQUIxFDASBgoJkiaJk/IsZAEZFgRaRVJPMRAwDgYDVQQDEwdaZXJv
# U0NBAhNYAAAAPDajznxlIudFAAAAAAA8MAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEWBBQezA1jezWq
# 2y85lZeNYhYTakBiEjANBgkqhkiG9w0BAQEFAASCAQB1pjPvGPG37MQ1bGTj/JgQ
# 87kMqcY/O84OejllTicj6Gy03tB0xlrhZ8/u1HtP16Bei5z7gJO6y8v1r7/xP3fV
# lOK+XUlcUzqmWBpLSQg5AbrqEALqKvmHXlX610D6Ygn2mR+GbxCRmi1ZaBor7jFp
# gnz8u/6WItCgQeZvLewiJTsMR99HLjILDnXHMT7JnKtHFkLhGKsCgPWWJHimoJhd
# vGQNJhjXpXc2j+MLL40EJ5o15SyYRP0ResHaTNLdKBPpLjPd14Oiqnge7lxWKrnv
# 1609ItrH4hvm24pHK3Ou6DwATmg9BmE0C2ofmTAvtVN9bqUg7o4w/MuOO5ri5rA1
# SIG # End signature block
