using module "C:\Users\fawohlsc\Repos\azure-policy-testing\utils\TestContext.psm1"

BeforeDiscovery {
    # Suppress breaking change warning in Azure PowerShell
    # See also: https://github.com/Azure/azure-powershell/blob/master/documentation/breaking-changes/breaking-changes-messages-help.md
    Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"
}