Import-Module -Name Az.Network
Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/Rest.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/Test.Utils.psm1" -Force

<#
.SYNOPSIS
Gets route 0.0.0.0/0 pointing to the virtual appliance.

.DESCRIPTION
Gets route 0.0.0.0/0 pointing to the virtual appliance which is provisioned as part of the landing zone.

.PARAMETER RouteTable
The route table containing the route 0.0.0.0/0 pointing to the virtual appliance.

.EXAMPLE
$route = $RouteTable | Get-RouteNextHopVirtualAppliance 

.EXAMPLE
$route = Get-RouteNextHopVirtualAppliance -RouteTable $routeTable
#>
function Get-RouteNextHopVirtualAppliance {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSRouteTable]$RouteTable
    )
    
    $nextHopIpAddress = Get-VirtualApplianceIpAddress -Location $RouteTable.Location
    
    $route = $RouteTable.Routes | Where-Object { 
        ($_.AddressPrefix -eq "0.0.0.0/0") -and
        ($_.NextHopType -eq "VirtualAppliance") -and
        ($_.NextHopIpAddress -eq $nextHopIpAddress)
    } | Select-Object -First 1 # Address prefixes are unique within a route table.

    return $route
}

<#
.SYNOPSIS
Gets the IP address of the virtual appliance.

.DESCRIPTION
Gets the IP address of the virtual appliance for the respective Azure region. The test environment is based on a hub/spoke network topology, with a virtual appliance deployed in each hub and each hub provisioned per Azure region. When no location is provided, the default location is retrieved by using Get-ResourceLocationDefault.

.PARAMETER Location
The Azure region where the virtual appliance is deployed to, e.g. northeurope. 

.EXAMPLE
$nextHopIpAddress = Get-VirtualApplianceIpAddress -Location $RouteTable.Location

.EXAMPLE
$nextHopIpAddress = Get-VirtualApplianceIpAddress
#>
function Get-VirtualApplianceIpAddress {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Location = (Get-ResourceLocationDefault)
    )

    $virtualApplianceIpAddress > $null
    switch ($Location) {
        "northeurope" { $virtualApplianceIpAddress = "10.0.0.23"; break }
        "westeurope" { $virtualApplianceIpAddress = "10.1.0.23"; break }
        default { throw "Location '$($Location)' not handled." }
    }

    return $virtualApplianceIpAddress
}

<#
.SYNOPSIS
Deletes a route in a route table.

.DESCRIPTION
Deletes a route in a route table by directly invoking the Azure REST API.

.PARAMETER RouteTable
The route table containing the route to be deleted.

.PARAMETER Route
The route to be deleted.

.EXAMPLE
$routeTable | Invoke-RouteDelete -Route $route

.LINK
https://docs.microsoft.com/en-us/rest/api/virtualnetwork/routes/delete
#>
function Invoke-RouteDelete {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSRouteTable]$RouteTable,
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSRoute]$Route
    )

    $httpResponse = Invoke-AzRestMethod `
        -ResourceGroupName $RouteTable.ResourceGroupName `
        -ResourceProviderName "Microsoft.Network" `
        -ResourceType @("routeTables", "routes") `
        -Name @($RouteTable.Name, $Route.Name) `
        -ApiVersion "2020-05-01" `
        -Method "DELETE"

    # Handling the HTTP status codes returned by the DELETE request for route 
    # See also: https://docs.microsoft.com/en-us/rest/api/virtualnetwork/routes/delete
    # Accepted.
    if ($httpResponse.StatusCode -eq 200) {
        # All good, do nothing
    }
    # Accepted and the operation will complete asynchronously.
    elseif ($httpResponse.StatusCode -eq 202) {
        # Invoke-AzRestMethod currently does not support awaiting asynchronous operations
        # See also: https://github.com/Azure/azure-powershell/issues/13293
        $asyncOperation = $httpResponse | Wait-AsyncOperation
        if ($asyncOperation.Status -ne "Succeeded") {
            throw "Asynchronous operation failed with message: '$($asyncOperation)'"
        }
    }
    # Route was deleted or not found.
    elseif ($httpResponse.StatusCode -eq 204) {
        # All good, do nothing.
    }
    # Error response describing why the operation failed.
    else {
        throw "Operation failed with message: '$($httpResponse.Content)'"
    }
}

<#
.SYNOPSIS
Creates or updates a route in a route table.

.DESCRIPTION
Creates or updates a route in a route table by directly invoking the Azure REST API.

.PARAMETER RouteTable
The route table containing the route to be created or updated.

.PARAMETER Name
The name of the route.

.PARAMETER AddressPrefix
The destination CIDR to which the route applies.

.PARAMETER NextHopType
The type of Azure hop the packet should be sent to.

.PARAMETER NextHopIpAddress
The IP address packets should be forwarded to. Next hop values are only allowed in routes where the next hop type is VirtualAppliance.

.EXAMPLE
$routeTable | Invoke-RoutePut -Name "container-registry" -AddressPrefix "13.69.227.80/29" -NextHopType "Internet"

.LINK
https://docs.microsoft.com/en-us/rest/api/virtualnetwork/routes/createorupdate
#>
function Invoke-RoutePut {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSRouteTable]$RouteTable,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AddressPrefix,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$NextHopType,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$NextHopIpAddress
    )

    $payload = @"
{
    "properties":   {
        "addressPrefix": "$($AddressPrefix)",
        "nextHopType": "$($NextHopType)",
        "nextHopIpAddress": "$($NextHopIpAddress)"
    }
}
"@
    
    $httpResponse = Invoke-AzRestMethod `
        -ResourceGroupName $RouteTable.ResourceGroupName `
        -ResourceProviderName "Microsoft.Network" `
        -ResourceType @("routeTables", "routes") `
        -Name @($RouteTable.Name, $Name) `
        -ApiVersion "2020-05-01" `
        -Method "PUT" `
        -Payload $payload

    # Handling the HTTP status codes returned by the PUT request for route. 
    # See also: https://docs.microsoft.com/en-us/rest/api/virtualnetwork/routes/createorupdate
    # Update successful. The operation returns the resulting Route resource.
    if ($httpResponse.StatusCode -eq 200) {
        # All good, do nothing.
    }
    # Create successful. The operation returns the resulting Route resource.
    elseif ($httpResponse.StatusCode -eq 201) {
        # Invoke-AzRestMethod currently does not support awaiting asynchronous operations.
        # See also: https://github.com/Azure/azure-powershell/issues/13293
        $asyncOperation = $httpResponse | Wait-AsyncOperation
        if ($asyncOperation.Status -ne "Succeeded") {
            throw "Asynchronous operation failed with message: '$($asyncOperation)'"
        }
    }
    # Error response describing why the operation failed.
    else {
        throw "Operation failed with message: '$($httpResponse.Content)'"
    }
}

<#
.SYNOPSIS
Tests whether a route table contains the route 0.0.0.0/0 pointing to the virtual appliance.

.DESCRIPTION
Tests whether a route table contains the route 0.0.0.0/0 pointing to the virtual appliance, which is provisioned as part of the landing zone.

.PARAMETER RouteTable
The route table to be tested.

.EXAMPLE
$routeTable | Test-RouteNextHopVirtualAppliance | Should -BeTrue
#>
function Test-RouteNextHopVirtualAppliance {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSRouteTable]$RouteTable
    )
    
    $route = Get-RouteNextHopVirtualAppliance -RouteTable $RouteTable

    return $null -ne $route
}