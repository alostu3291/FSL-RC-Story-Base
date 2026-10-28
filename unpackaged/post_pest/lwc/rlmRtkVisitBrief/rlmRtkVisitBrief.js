import { LightningElement, api } from 'lwc';
import getBrief from '@salesforce/apex/RLM_RTK_AI.getBrief';

/**
 * Pre-visit brief at the top of the visit: why the customer called, their plan and history, open
 * invoices and what to look for. Written by Einstein when it's on, from the records otherwise, and
 * kept on the work order so the last brief still shows without a connection.
 */
export default class RlmRtkVisitBrief extends LightningElement {
    @api recordId;
    brief;
    loading = true;
    error;
    open = true;

    connectedCallback() {
        this.load(false);
    }

    async load(regenerate) {
        this.loading = true;
        this.error = undefined;
        try {
            this.brief = await getBrief({ recordId: this.recordId, regenerate });
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'The brief is not available right now.';
        } finally {
            this.loading = false;
        }
    }

    refresh() {
        this.load(true);
    }

    toggle() {
        this.open = !this.open;
    }

    get toggleLabel() {
        return this.open ? 'Hide' : 'Show';
    }

    get points() {
        return ((this.brief && this.brief.points) || []).map((text, i) => ({ key: `p${i}`, text }));
    }

    get lookFor() {
        return ((this.brief && this.brief.lookFor) || []).map((text, i) => ({ key: `l${i}`, text }));
    }

    get hasLookFor() {
        return this.lookFor.length > 0;
    }

    get sourceLabel() {
        if (!this.brief) return '';
        const when = this.brief.generatedAt
            ? new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(
                  new Date(this.brief.generatedAt)
              )
            : '';
        return `${this.brief.aiGenerated ? 'Einstein' : 'From the records'}${when ? ` · ${when}` : ''}`;
    }

    get badgeClass() {
        return this.brief && this.brief.aiGenerated ? 'badge ai' : 'badge';
    }
}
