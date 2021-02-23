Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/Policy.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/Resource.Utils.psm1" -Force

<#
.SYNOPSIS
Cleans up any Azure resources created during the test.

.DESCRIPTION
Cleans up any Azure resources created during the test. If any clean-up operation fails, the whole test will fail.

.PARAMETER CleanUp
The script block specifying the clean-up operations.

.EXAMPLE
AzCleanUp {
    Remove-AzResourceGroup -Name $ResourceGroup.ResourceGroupName -Force
}
#>
function AzCleanUp {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [ScriptBlock] $CleanUp
    )

    try {
        # Remember $ErrorActionPreference.
        $errorAction = $ErrorActionPreference

        # Stop clean-up on errors, since $ErrorActionPreference defaults to 'Continue' in PowerShell.
        $ErrorActionPreference = "Stop" 

        # Execute clean-up script.
        $CleanUp.Invoke()

        # Reset $ErrorActionPreference to previous value.
        $ErrorActionPreference = $errorAction
    }
    catch {
        throw "Clean-up failed with message: '$($_)'"
    }
}

function AzPolicyTest {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [ScriptBlock] $Test,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PolicyDefinitionName,
        [Parameter()]
        [ValidateNotNull()]
        [Hashtable] $PolicyParameterObject = @{}
    )

    try {
        # Get Azure context
        $context = Get-AzContext
            
        # Check whether test is executed using a service principal, which is required to login again after policy assignment.
        if ($context.Account.Type -ne "ServicePrincipal") {
            throw "Test for policy '$($PolicyDefinitionName)' has to be executed using a service principal."
        }

        # Create resource group for test.
        $resourceGroup = New-AzResourceGroup `
            -Name (New-Guid).Guid `
            -Location (Get-ResourceLocationDefault)

        # Assign policy to resource group.
        New-PolicyAssignment `
            -ResourceGroup $resourceGroup `
            -PolicyDefinitionName $PolicyDefinitionName `
            -PolicyParameterObject $PolicyParameterObject

        # Login again to make sure policy assignment is applied.
        $password = ConvertTo-SecureString $context.Account.ExtendedProperties.ServicePrincipalSecret -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($context.Account.Id, $password)
        Connect-AzAccount `
            -Tenant $context.Tenant.Id `
            -Subscription $context.Subscription.Id `
            -Credential $credential `
            -ServicePrincipal `
            -Scope Process `
            > $null
            
        # Invoke test.
        Invoke-Command -ScriptBlock $Test -ArgumentList $resourceGroup
    }
    finally {
        # Stops on failures during clean-up. 
        AzCleanUp {
            Remove-AzResourceGroup -Name $resourceGroup.ResourceGroupName -Force -AsJob
        }
    }
}