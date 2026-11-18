/** Verdant hosted MCP tool book_treatment. */
public with sharing class RLM_RTK_McpBookTreatment {
    public class Request {
        @InvocableVariable(label='Appointment Id' description='The treatment\'s service appointment Id.' required=true)
        public String appointmentId;
        @InvocableVariable(label='Start Time' description='A slot\'s startTime value exactly as find_treatment_slots returned it.' required=true)
        public String startTime;
    }

    @InvocableMethod(label='Verdant: Book treatment' description='Books the first treatment at the slot the customer picked and dispatches it to the technician.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'appointmentId' => r.appointmentId, 'startTime' => r.startTime });
        }
        return RLM_RTK_McpTool.callEach('bookTreatment', params);
    }
}
