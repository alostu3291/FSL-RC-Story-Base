/** Verdant hosted MCP tool get_plan_pricing. */
public with sharing class RLM_RTK_McpGetPlanPricing {
    public class Request {
        @InvocableVariable(label='Postal Code' description='Defaults to 60108.')
        public String postalCode;
    }

    @InvocableMethod(label='Verdant: Get plan pricing' description='Plan prices for a service zone, with the home size and severity adjustments Salesforce applies.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'postalCode' => String.isBlank(r.postalCode) ? '60108' : r.postalCode });
        }
        return RLM_RTK_McpTool.callEach('pricing', params);
    }
}
