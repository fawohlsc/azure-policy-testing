using module Az.Network
using module Az.Resources
using module "../utils/TestContext.psm1"
using module  "../utils/Rest.Utils.psm1"
using module  "../utils/Policy.Utils.psm1"
using module  "../utils/Test.Utils.psm1"
using module  "../utils/RouteTable.Utils.psm1"

Describe "Testing policy 'Audit-Route-NextHopVirtualAppliance'" -Tag "audit-route-nexthopvirtualappliance" {
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
    
    Context "When auditing route tables" {
        It "Should mark route table as compliant with route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-compliant" {
            # Create an unique resource group, assign the policy to the resource group and execute the test.
            # After executing the test, the policy assignment and resource group will be deleted.
            AzPolicyTest -TestContext $TestContext {
                # Create compliant route table with route 0.0.0.0/0 pointing to the virtual appliance.
                $route = New-AzRouteConfig `
                    -Name "default" `
                    -AddressPrefix "0.0.0.0/0" `
                    -NextHopType "VirtualAppliance" `
                    -NextHopIpAddress $TestContext.PolicyParameterObject.routeTableSettings.northeurope.virtualApplianceIpAddress
                                
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -Location $TestContext.ResourceGroup.Location `
                    -Route $Route

                # Trigger compliance scan for resource group and wait for completion.
                Complete-PolicyComplianceScan -TestContext $TestContext 

                # Verify that route table is compliant.
                Get-PolicyComplianceState `
                    -Resource $routeTable `
                    -TestContext $TestContext
                | Should -BeTrue
            }
        }

        It "Should mark route table as incompliant without route 0.0.0.0/0 pointing to virtual appliance." -Tag "audit-route-nexthopvirtualappliance-incompliant" {
            # Create an unique resource group, assign the policy to the resource group and execute the test.
            # After executing the test, the policy assignment and resource group will be deleted.
            AzPolicyTest -TestContext $TestContext {
                # Create incompliant route table without route 0.0.0.0/0 pointing to the virtual appliance.
                $routeTable = New-AzRouteTable `
                    -Name "route-table" `
                    -ResourceGroupName $TestContext.ResourceGroup.ResourceGroupName `
                    -Location $TestContext.ResourceGroup.Location `
                    -Route $Route

                # Trigger compliance scan for resource group and wait for completion.
                Complete-PolicyComplianceScan -TestContext $TestContext 

                # Verify that route table is incompliant.
                Get-PolicyComplianceState `
                    -Resource $routeTable `
                    -TestContext $TestContext
                | Should -BeFalse
            }
        }
    }

    AfterAll {
        # After all tests, delete the unique policy definition at subscription scope.
        Clear-AzPolicyTest -TestContext $TestContext
    }
}
