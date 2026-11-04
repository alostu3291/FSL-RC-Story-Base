trigger RLM_HVAC_ServiceAppointmentTrigger on ServiceAppointment (after update) {
    RLM_HVAC_Coverage.appointmentsChanged(Trigger.new, Trigger.oldMap);
}
