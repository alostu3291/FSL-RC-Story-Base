/** Verdant hosted MCP tool find_treatment_slots. */
public with sharing class RLM_RTK_McpFindTreatmentSlots {
    public class Request {
        @InvocableVariable(label='Appointment Id' description='The treatment\'s service appointment Id (treatmentAppointmentId from get_order_status).' required=true)
        public String appointmentId;
    }

    @InvocableMethod(label='Verdant: Find treatment slots' description='Open times for the first treatment. Offer two or three to the customer.' category='Verdant Field Assistant')
    public static List<RLM_RTK_McpTool.Response> run(List<Request> requests) {
        List<Map<String, Object>> params = new List<Map<String, Object>>();
        for (Request r : requests) {
            params.add(new Map<String, Object>{ 'appointmentId' => r.appointmentId });
        }
        return RLM_RTK_McpTool.callEach('treatmentSlots', params);
    }
}
