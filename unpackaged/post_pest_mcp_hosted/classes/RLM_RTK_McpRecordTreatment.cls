/** Verdant hosted MCP tool record_treatment. */
public with sharing class RLM_RTK_McpRecordTreatment {
    public class Request {
        @InvocableVariable(label='Visit' description='The visit: a work order Id or service appointment Id from get_my_schedule.' required=true)
        public String visit;
        @InvocableVariable(label='Finding Id' description='The finding\'s Id from get_treatment_checklist.' required=true)
        public String findingId;
        @InvocableVariable(label='Status' description='One of: Treated, Needs Follow-up, Open.' required=true)
        public String status;
        @InvocableVariable(label='Note' description='What was done, in plain language for the visit summary.' required=true)
        public String note;
    }

    @InvocableMethod(label='Verdant: Record treatment' description='Records the treatment of one finding.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'recordId' => r.visit, 'findingId' => r.findingId, 'status' => r.status, 'note' => r.note });
        }
        return RLM_RTK_McpTool.callEach('recordTreatment', params);
    }
}
