/** Verdant hosted MCP tool get_add_on_options. */
public with sharing class RLM_RTK_McpGetAddOnOptions {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
    }

    @InvocableMethod(label='Verdant: Get add-on options' description='One-time add-on services (wasp nest removal, rodent exclusion, attic sanitation, bed bug treatment) with prices, which ones the findings recommend, and what\'s already added to this visit.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit });
        }
        return RLM_RTK_McpTool.callEach('addOnOptions', params);
    }
}
