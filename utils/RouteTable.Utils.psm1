Import-Module -Name Az.Network
Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/Rest.Utils.psm1" -Force

function Get-Route {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [Microsoft.Azure.Commands.Network.Models.PSRouteTable]$RouteTable,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AddressPrefix
    )
    
    $route = $RouteTable.Routes | Where-Object { 
        $_.AddressPrefix -eq $AddressPrefix
    } | Select-Object -First 1 # Address prefixes are unique within a route table.

    return $route
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