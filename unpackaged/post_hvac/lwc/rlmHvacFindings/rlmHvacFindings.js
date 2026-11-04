import { LightningElement, api, wire } from 'lwc';
import getQuoteFindings from '@salesforce/apex/RLM_HVAC_Assessment.getQuoteFindings';

const TONES = { Monitor: 'light', 'Repair Soon': 'moderate', Safety: 'heavy' };
const toneFor = (urgency) => TONES[urgency] || 'light';

/** Customer-facing system check behind a quote: equipment, what we found, photos and why the agreement fits. */
export default class RlmHvacFindings extends LightningElement {
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
        this.error = error ? (error.body && error.body.message) || 'Could not load the system check' : undefined;
    }

    get hasFindings() {
        return !!(this.state && this.state.findings && this.state.findings.length);
    }

    get findings() {
        return (this.state.findings || []).map((f) => ({
            ...f,
            observation: [f.component, f.condition].filter(Boolean).join(' – ') || (f.make ? 'Data plate' : 'Observation'),
            equipmentLine: [f.make, f.modelNumber, f.installYear ? `installed ${f.installYear}` : null].filter(Boolean).join(' · '),
            urgencyLabel: f.urgency || 'Monitor',
            sevClass: `sev-pill ${toneFor(f.urgency)}`,
            hasPhotos: f.photos && f.photos.length > 0
        }));
    }

    get photoCount() {
        return (this.state.findings || []).reduce((n, f) => n + (f.photos ? f.photos.length : 0), 0);
    }

    get findingCount() {
        return this.state.findings.length;
    }

    get urgency() {
        return (this.state.recommendation && this.state.recommendation.urgency) || 'Monitor';
    }

    get urgencyClass() {
        return `sev-pill ${toneFor(this.urgency)}`;
    }

    get replacementRecommended() {
        return !!(this.state.recommendation && this.state.recommendation.replacementRecommended);
    }

    previewPhoto(event) {
        const { url, title } = event.currentTarget.dataset;
        this.viewing = { url, title };
    }

    closePhoto() {
        this.viewing = undefined;
    }
}
