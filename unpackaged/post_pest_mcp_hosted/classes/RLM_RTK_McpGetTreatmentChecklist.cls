/** Verdant hosted MCP tool get_treatment_checklist. */
public with sharing class RLM_RTK_McpGetTreatmentChecklist {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
    }

    @InvocableMethod(label='Verdant: Get treatment checklist' description='The findings to treat on this visit, from the inspection, with their treatment status.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit });
        }
        return RLM_RTK_McpTool.callEach('inspection', params);
    }
}
