BeforeDiscovery {
    # Suppress breaking change warning in Azure PowerShell
    # See also: https://github.com/Azure/azure-powershell/blob/master/documentation/breaking-changes/breaking-changes-messages-help.md
    Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

    # Import modules
    Import-Module -Name Az.Network
    Import-Module -Name Az.Resources

    # Import scripts
    $scripts = @( Get-ChildItem -Path $PSScriptRoot\..\utils\*.ps1 -ErrorAction SilentlyContinue )

    # Dot source the scripts
    foreach ($script in $scripts) {
        try {
            . $script.fullname
        }
        catch {
            Write-Error -Message "Failed to import script $($scipt.fullname): $_"
        }
    }
}