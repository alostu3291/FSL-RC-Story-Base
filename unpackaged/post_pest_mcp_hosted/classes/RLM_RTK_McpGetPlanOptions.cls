/** Verdant hosted MCP tool get_plan_options. */
public with sharing class RLM_RTK_McpGetPlanOptions {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
    }

    @InvocableMethod(label='Verdant: Get plan options' description='The customer\'s current plan and monthly total, and every tier or add-on plan they could move to with its new monthly price.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit });
        }
        return RLM_RTK_McpTool.callEach('planOptions', params);
    }
}
