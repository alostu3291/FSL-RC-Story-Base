import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import completeVisit from '@salesforce/apex/RLM_RTK_FieldVisit.completeVisit';

/** Quick action wrapper so the Treatment Checklist can run in the Field Service mobile app. */
export default class RlmRtkTreatmentAction extends LightningElement {
    @api recordId;
    busy = false;
    error;
    completedNumber;

    async complete() {
        this.busy = true;
        this.error = undefined;
        try {
            this.completedNumber = await completeVisit({ recordId: this.recordId });
        } catch (e) {
            this.error = (e && e.body && e.body.message) || (e && e.message) || 'Could not complete the visit.';
        } finally {
            this.busy = false;
        }
    }

    handleFindingAdded() {
        const checklist = this.template.querySelector('.checklist');
        if (checklist) checklist.refresh();
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}
