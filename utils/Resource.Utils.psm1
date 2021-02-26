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