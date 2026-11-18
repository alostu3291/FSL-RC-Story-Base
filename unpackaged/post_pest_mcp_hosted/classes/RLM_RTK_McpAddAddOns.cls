/** Verdant hosted MCP tool add_add_ons. */
public with sharing class RLM_RTK_McpAddAddOns {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
        @InvocableVariable(label='SKUs' description='Comma-separated add-on SKUs from get_add_on_options, for example RTK-WASP-NEST.' required=true)
        public String skus;
        @InvocableVariable(label='Approved By' description='Name of the customer who said yes to this on site. Ask them first.' required=true)
        public String approvedBy;
    }

    @InvocableMethod(label='Verdant: Add add-ons' description='Adds one-time add-ons the customer approved; they\'re billed on the next invoice.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit, 'skus' => r.skus, 'approvedBy' => r.approvedBy });
        }
        return RLM_RTK_McpTool.callEach('addAddOns', params);
    }
}
