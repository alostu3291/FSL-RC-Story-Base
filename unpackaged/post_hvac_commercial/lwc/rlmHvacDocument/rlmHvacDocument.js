import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import latest from '@salesforce/apex/RLM_HVAC_CommercialDocuments.latest';
import create from '@salesforce/apex/RLM_HVAC_CommercialDocuments.create';
import check from '@salesforce/apex/RLM_HVAC_CommercialDocuments.check';

const POLL_MS = 3000;
const MAX_POLLS = 40;

/** Creates and opens the Brightline Commercial PDF for a quote or invoice: contract proposal, project proposal or consolidated invoice. */
export default class RlmHvacDocument extends NavigationMixin(LightningElement) {
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        const changed = value !== this._recordId;
        this._recordId = value;
        if (value && changed) this.load();
    }

    _recordId;
    doc;
    error;
    busy = false;
    polls = 0;
    timer;

    disconnectedCallback() {
        clearTimeout(this.timer);
    }

    async load() {
        try {
            this.doc = await latest({ recordId: this._recordId });
            this.error = undefined;
        } catch (e) {
            this.doc = undefined;
            this.error = this.message(e, 'Could not load the document.');
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    get kind() {
        return (this.doc && this.doc.kind) || 'document';
    }

    get ready() {
        return this.doc && this.doc.status === 'Ready';
    }

    get generating() {
        return this.doc && this.doc.status === 'Generating';
    }

    get failed() {
        return this.doc && this.doc.status === 'Failed';
    }

    get createLabel() {
        return this.ready ? 'Create again' : `Create ${this.kind} PDF`;
    }

    get openLabel() {
        return `Open ${this.kind}`;
    }

    get progressText() {
        return `Creating the ${this.kind}. This takes about half a minute.`;
    }

    async generate() {
        this.busy = true;
        this.error = undefined;
        try {
            this.doc = await create({ recordId: this._recordId });
            this.polls = 0;
            this.schedule();
        } catch (e) {
            this.error = this.message(e, `Could not create the ${this.kind}.`);
        } finally {
            this.busy = false;
        }
    }

    schedule() {
        clearTimeout(this.timer);
        if (!this.generating) return;
        if (this.polls >= MAX_POLLS) {
            this.error = `The ${this.kind} is taking longer than usual. Check the record's files in a minute.`;
            return;
        }
        this.polls++;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timer = setTimeout(() => this.poll(), POLL_MS);
    }

    async poll() {
        try {
            this.doc = await check({ processId: this.doc.processId, recordId: this._recordId });
            if (this.ready) this.open();
            this.schedule();
        } catch (e) {
            this.error = this.message(e, `Could not check the ${this.kind}.`);
        }
    }

    open() {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: this.doc.contentDocumentId }
        });
    }
}
