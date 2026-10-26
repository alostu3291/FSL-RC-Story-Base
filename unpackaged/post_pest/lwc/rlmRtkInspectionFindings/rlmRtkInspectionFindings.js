import { LightningElement, api, wire } from 'lwc';
import getQuoteFindings from '@salesforce/apex/RLM_RTK_Inspection.getQuoteFindings';

export default class RlmRtkInspectionFindings extends LightningElement {
    @api quoteId;
    @api recordId;

    state;
    error;
    viewing;

    get targetId() {
        return this.quoteId || this.recordId;
    }

    @wire(getQuoteFindings, { quoteId: '$targetId' })
    wired({ data, error }) {
        this.state = data;
        this.error = error ? (error.body && error.body.message) || 'Could not load the inspection' : undefined;
    }

    get hasFindings() {
        return !!(this.state && this.state.findings && this.state.findings.length);
    }

    get findings() {
        return (this.state.findings || []).map((f) => ({
            ...f,
            observation: [f.pest, f.evidence].filter(Boolean).join(' – ') || 'Observation',
            sevClass: `sev-pill ${(f.severity || 'Light').toLowerCase()}`,
            hasPhotos: f.photos && f.photos.length > 0
        }));
    }

    get photoCount() {
        return (this.state.findings || []).reduce((n, f) => n + (f.photos ? f.photos.length : 0), 0);
    }

    get findingCount() {
        return this.state.findings.length;
    }

    get severity() {
        return (this.state.recommendation && this.state.recommendation.severity) || 'Light';
    }

    get severityClass() {
        return `sev-pill ${this.severity.toLowerCase()}`;
    }

    previewPhoto(event) {
        const { url, title } = event.currentTarget.dataset;
        this.viewing = { url, title };
    }

    closePhoto() {
        this.viewing = undefined;
    }
}
