import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import completeVisit from '@salesforce/apex/RLM_RTK_FieldVisit.completeVisit';
import getVisitTiming from '@salesforce/apex/RLM_RTK_FieldVisit.getVisitTiming';
import startVisit from '@salesforce/apex/RLM_RTK_FieldVisit.startVisit';

/** Quick action wrapper so the Treatment Checklist can run in the Field Service mobile app. */
export default class RlmRtkTreatmentAction extends LightningElement {
    _recordId;
    busy = false;
    error;
    completedNumber;
    timing;

    // Quick actions can set recordId after connectedCallback, so load from the setter too.
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        const changed = value !== this._recordId;
        this._recordId = value;
        if (value && changed) this.loadTiming();
    }

    async loadTiming() {
        try {
            this.timing = await getVisitTiming({ recordId: this._recordId });
        } catch (e) {
            this.error = this.message(e, 'Could not load the visit.');
        }
    }

    get loaded() {
        return !!this.timing;
    }
    get started() {
        return !!(this.timing && this.timing.startedAt);
    }
    get startedLabel() {
        if (!this.started) return '';
        const at = new Date(this.timing.startedAt).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
        return this.timing.appointmentNumber ? `Started at ${at} · ${this.timing.appointmentNumber}` : `Started at ${at}`;
    }

    async start() {
        this.busy = true;
        this.error = undefined;
        try {
            this.timing = await startVisit({ recordId: this._recordId });
        } catch (e) {
            this.error = this.message(e, 'Could not start the visit.');
        } finally {
            this.busy = false;
        }
    }

    async complete() {
        this.busy = true;
        this.error = undefined;
        try {
            this.completedNumber = await completeVisit({ recordId: this._recordId });
        } catch (e) {
            this.error = this.message(e, 'Could not complete the visit.');
        } finally {
            this.busy = false;
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    handleFindingAdded() {
        const checklist = this.template.querySelector('.checklist');
        if (checklist) checklist.refresh();
        const planChange = this.template.querySelector('.plan-change');
        if (planChange) planChange.refresh();
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}
