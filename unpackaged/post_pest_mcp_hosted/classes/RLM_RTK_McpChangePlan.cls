/** Verdant hosted MCP tool change_plan. */
public with sharing class RLM_RTK_McpChangePlan {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
        @InvocableVariable(label='SKU' description='The tier or add-on plan SKU from get_plan_options.' required=true)
        public String sku;
        @InvocableVariable(label='Approved By' description='Name of the customer who said yes to this on site. Ask them first.' required=true)
        public String approvedBy;
    }

    @InvocableMethod(label='Verdant: Change plan' description='Upgrades, downgrades, adds or removes a plan through a Revenue Cloud amendment, from tomorrow. Assets, guarantees, visits and prorated billing follow automatically.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit, 'sku' => r.sku, 'approvedBy' => r.approvedBy });
        }
        return RLM_RTK_McpTool.callEach('changePlan', params);
    }
}
