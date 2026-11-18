/** Verdant hosted MCP tool get_customer_summary. */
public with sharing class RLM_RTK_McpGetCustomerSummary {
    public class Request {
        @InvocableVariable(label='Customer' description='Customer name as it appears in Salesforce (for example Sam Patel) or an Account Id.' required=true)
        public String customer;
    }

    @InvocableMethod(label='Verdant: Get customer summary' description='The customer\'s plans and monthly price, scheduled changes, guarantees, visits, invoices and balance.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'customer' => r.customer });
        }
        return RLM_RTK_McpTool.callEach('customerSummary', params);
    }
}
