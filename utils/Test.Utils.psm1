Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/Policy.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/Resource.Utils.psm1" -Force

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
        Remove-AzResourceGroup -Name $resourceGroup.ResourceGroupName -Force -AsJob
    }
}