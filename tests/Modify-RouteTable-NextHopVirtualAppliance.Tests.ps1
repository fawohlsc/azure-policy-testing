Import-Module -Name Az.Network
Import-Module -Name Az.Resources
Import-Module "$($PSScriptRoot)/../utils/Policy.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/Rest.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/RouteTable.Utils.psm1" -Force
Import-Module "$($PSScriptRoot)/../utils/Test.Utils.psm1" -Force

Describe "Testing policy 'Modify-RouteTable-NextHopVirtualAppliance'" -Tag "modify-routetable-nexthopvirtualappliance" {
    BeforeAll {
        # Before all tests, initialize the test context and create an unique policy definition at subscription scope.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $TestContext = Initialize-AzPolicyTest -PolicyParameterObject @{
            "routeTableSettings" = @{
                "northeurope" = @{
                    "virtualApplianceIpAddress" = "10.0.0.23"
                }; 
                "disabled"    = @{
                    "virtualApplianceIpAddress" = ""
                }
            }
        }
    }
    
    # Create or update route tables is actually the same PUT request, hence testing create covers update as well.
    # PATCH requests are currently not supported in Network Resource Provider.
    # See also: https://docs.microsoft.com/en-us/rest/api/virtualnetwork/routetables/createorupdate
    Context "When route table is created or updated" -Tag "modify-routetable-nexthopvirtualappliance-routetable-create-update" {
        It "Should add missing route 0.0.0.0/0 pointing to the virtual appliance" -Tag "modify-routetable-nexthopvirtualappliance-routetable-create-update-10" {
            # Create an unique resource group, assign the policy to the resource group and execute the test.
            # After executing the test, the policy assignment and resource group will be deleted.
            AzPolicyTest -TestContext $TestContext {
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -Location $TestContext.ResourceGroup.Location
            
                # Verify that route 0.0.0.0/0 was added by policy.
                $route = Get-Route -RouteTable $routeTable -AddressPrefix "0.0.0.0/0"
                $route | Should -Not -BeNullOrEmpty
                $route.NextHopType | Should -Be "VirtualAppliance"
                $route.NextHopIpAddress | Should -Be $TestContext.PolicyParameterObject.routeTableSettings.northeurope.virtualApplianceIpAddress
            }
        }
    }

    Context "When route is deleted" -Tag "modify-routetable-nexthopvirtualappliance-route-delete" {
        It "Should remediate missing route 0.0.0.0/0 pointing to the virtual appliance" -Tag "modify-routetable-nexthopvirtualappliance-route-delete-10" {
            # Create an unique resource group, assign the policy to the resource group and execute the test.
            # After executing the test, the policy assignment and resource group will be deleted.
            AzPolicyTest -TestContext $TestContext {
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -Location $TestContext.ResourceGroup.Location

                # Get route 0.0.0.0/0 pointing to the virtual appliance, which was added by policy.
                $route = Get-Route -RouteTable $routeTable -AddressPrefix "0.0.0.0/0"

                # Remove-AzRouteConfig/Set-AzRouteTable will issue a PUT request for routeTables and hence policy might kick in.
                # In order to delete the route without policy interfering, directly call the REST API by issuing a DELETE request for route.
                $routeTable | Invoke-RouteDelete -Route $route
            
                # Remediate route table by policy and wait for completion.
                $routeTable | Complete-PolicyRemediation -TestContext $TestContext -CheckDeployment
            
                # Verify that route 0.0.0.0/0 was added by policy remediation.
                $route = Get-Route -RouteTable $routeTable -AddressPrefix "0.0.0.0/0"
                $route | Should -Not -BeNullOrEmpty
                $route.NextHopType | Should -Be "VirtualAppliance"
                $route.NextHopIpAddress | Should -Be $TestContext.PolicyParameterObject.routeTableSettings.northeurope.virtualApplianceIpAddress
            }
        }
    }

    AfterAll {
        # After all tests, delete the unique policy definition at subscription scope.
        Clear-AzPolicyTest -TestContext $TestContext
    }
}