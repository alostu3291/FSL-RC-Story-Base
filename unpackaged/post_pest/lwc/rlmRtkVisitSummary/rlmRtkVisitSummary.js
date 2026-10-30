import { LightningElement, api } from 'lwc';
import summarizeVisit from '@salesforce/apex/RLM_RTK_AI.summarizeVisit';

/** Shown once a visit is complete: the summary written for the customer, saved on the work order and emailed. */
export default class RlmRtkVisitSummary extends LightningElement {
    @api recordId;
    summary;
    loading = true;
    error;

    connectedCallback() {
        this.load();
    }

    async load() {
        this.loading = true;
        this.error = undefined;
        try {
            this.summary = await summarizeVisit({ recordId: this.recordId });
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'The visit summary could not be written.';
        } finally {
            this.loading = false;
        }
    }

    get sentLabel() {
        if (!this.summary) return '';
        if (this.summary.emailedTo) return `Emailed to ${this.summary.emailedTo}`;
        return this.summary.emailError || 'Saved on the work order.';
    }

    get sourceLabel() {
        return this.summary && this.summary.aiGenerated ? 'Einstein' : 'From the checklist';
    }

    get badgeClass() {
        return this.summary && this.summary.aiGenerated ? 'badge ai' : 'badge';
    }
}
