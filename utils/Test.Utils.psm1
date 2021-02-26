Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/Policy.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/Resource.Utils.psm1" -Force

function AzPolicyTest {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [ScriptBlock] $Test,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSObject] $TestContext
    )

    try {
        # Generate id for the test.
        $TestContext.Id = "$((New-Guid).Guid)"

        # Create resource group for the test.
        $TestContext.ResourceGroup = New-AzResourceGroup `
            -Name $TestContext.Id `
            -Location $TestContext.Location

        # Assign policy to the resource group.
        $TestContext.PolicyAssignment = New-PolicyAssignment $testContext

        # Invoke the test.
        Invoke-Command -ScriptBlock $Test
    }
    finally {
        # Remove policy assignment and resource group.
        if ($TestContext.PolicyAssignment) {
            Remove-AzPolicyAssignment -Id $TestContext.PolicyAssignment.ResourceId
        }

        if ($TestContext.ResourceGroup) {
            Remove-AzResourceGroup -Id $TestContext.ResourceGroup.ResourceId -Force -AsJob
        }
    }
}


function Clear-AzPolicyTest {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSObject] $TestContext
    )

    # Remove policy definition.
    if ($TestContext.PolicyDefinition) {
        Remove-AzPolicyDefinition -Id $TestContext.PolicyDefinition.ResourceId -Force
    }
}

function Initialize-AzPolicyTest {
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Policy,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $PolicyTemplateFile,
        [Parameter()]
        [ValidateNotNull()]
        [Hashtable] $PolicyParameterObject = @{},
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Location = "northeurope"
    )
       
    $testContext = [PSCustomObject]@{ 
        Id                    = $null
        Policy                = $null
        PolicyTemplateFile    = $null
        PolicyDefinition      = $null
        PolicyAssignment      = $null
        PolicyParameterObject = $PolicyParameterObject
        ResourceGroup         = $null
        Location              = $Location
    }

    # Initialize policy.
    if ($Policy) {
        $testContext.Policy = $Policy
    }
    else {
        # Determine policy by test file name.
        $testContext.Policy = (Split-Path $MyInvocation.PSCommandPath -Leaf) -replace ".Tests.ps1", ""
    }

    # Initialize policy template file.
    if ($PolicyTemplateFile) {
        $testContext.PolicyTemplateFile = $PolicyTemplateFile
    }
    else {
        # Determine policy path by test file path.
        $policyTemplateDirectory = (Get-Item $MyInvocation.PSCommandPath).Directory.Parent.FullName + [IO.Path]::DirectorySeparatorChar + "policies" + [IO.Path]::DirectorySeparatorChar
        $testContext.PolicyTemplateFile = $policyTemplateDirectory + $testContext.Policy + ".json"
    }

    if (-not (Test-Path $testContext.PolicyTemplateFile)) {
        throw "Policy '$($testContext.Policy)' was not found at '$($testContext.PolicyTemplateFile)'."
    }

    # Create policy definition at subscription scope
    $testContext.PolicyDefinition = New-PolicyDefinition $testContext

    return $testContext
}