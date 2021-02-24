Import-Module -Name Az.Resources

<#
.SYNOPSIS
Gets the default Azure region.

.DESCRIPTION
Gets the default Azure region, e.g. northeurope.

.EXAMPLE
$location = Get-ResourceLocationDefault
#>
function Get-ResourceLocationDefault {
    return "northeurope"
}

function Get-ResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSChildResource]$Resource
    )

    $resourceGroupId = $Resource.Id -replace "/providers.+", ""
    $resourceGroup = Get-AzResourceGroup -Id $resourceGroupId

    return $resourceGroup
}