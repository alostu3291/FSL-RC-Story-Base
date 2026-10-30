trigger RLM_RTK_ServiceAppointmentTrigger on ServiceAppointment (after update) {
    RLM_RTK_Coverage.appointmentsChanged(Trigger.new, Trigger.oldMap);
}
