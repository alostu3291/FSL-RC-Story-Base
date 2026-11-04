import { LightningElement, api } from 'lwc';
import getWorkOrderFindings from '@salesforce/apex/RLM_HVAC_Assessment.getWorkOrderFindings';
import saveWork from '@salesforce/apex/RLM_HVAC_Assessment.saveWork';
import saveStep from '@salesforce/apex/RLM_HVAC_Assessment.saveStep';

const STATUSES = [
    { value: 'Done', label: 'Done', tone: 'done' },
    { value: 'Needs Follow-up', label: 'Needs follow-up', tone: 'follow' }
];

const TONES = { Monitor: 'light', 'Repair Soon': 'moderate', Safety: 'heavy' };

const SYSTEM_LABELS = { AcFurnace: 'AC and furnace', HeatPump: 'Heat pump', Boiler: 'Boiler' };

export default class RlmHvacServiceChecklist extends LightningElement {
    @api workOrderId;

    // Quick actions can set recordId after connectedCallback, so load from the setter too.
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        const changed = value !== this._recordId;
        this._recordId = value;
        if (changed && this.isConnected) this.load();
    }

    _recordId;
    state;
    loaded = false;
    error;
    savingId;
    notes = {};
    readings = {};
    stepReadings = {};
    viewing;

    connectedCallback() {
        if (this.targetId) this.load();
    }

    get targetId() {
        return this.workOrderId || this.recordId;
    }

    @api
    refresh() {
        return this.load();
    }

    async load() {
        if (!this.targetId) return;
        try {
            this.apply(await getWorkOrderFindings({ workOrderId: this.targetId }));
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.loaded = true;
        }
    }

    apply(state) {
        this.state = state;
        this.error = undefined;
    }

    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong';
    }

    get hasState() {
        return !!(this.state && ((this.state.steps && this.state.steps.length) || this.hasFindings));
    }

    get hasFindings() {
        return !!(this.state && this.state.findings && this.state.findings.length);
    }

    get showEmpty() {
        return this.loaded && !this.hasState && !this.error;
    }

    get heading() {
        const name = this.state.workTypeName || '';
        return /tune-up/i.test(name) ? 'Tune-up checklist' : 'Service checklist';
    }

    get eyebrow() {
        const system = SYSTEM_LABELS[this.state.systemType] || 'AC and furnace';
        return this.state.assessmentName ? `${system} · from system check ${this.state.assessmentName}` : system;
    }

    get total() {
        return (this.state.steps || []).length + (this.state.findings || []).length;
    }

    get completed() {
        return (this.state.stepsDone || 0) + (this.state.doneCount || 0);
    }

    get progressStyle() {
        return `width: ${this.total ? Math.round((this.completed / this.total) * 100) : 0}%`;
    }

    get allDone() {
        return this.total > 0 && this.completed === this.total;
    }

    get stepCount() {
        return `${this.state.stepsDone || 0} of ${(this.state.steps || []).length}`;
    }

    get findingCount() {
        return `${this.state.doneCount || 0} of ${this.state.findings.length}`;
    }

    get steps() {
        return (this.state.steps || []).map((s) => ({
            ...s,
            rowClass: `step${s.done ? ' done' : ''}`,
            checkClass: `check${s.done ? ' on' : ''}`,
            ariaPressed: s.done ? 'true' : 'false',
            busy: this.savingId === s.key,
            readingValue: this.stepReadings[s.key] !== undefined ? this.stepReadings[s.key] : s.reading || '',
            readingLabel: `Reading (${s.readingHint})`
        }));
    }

    get findings() {
        return this.state.findings.map((f) => {
            const status = f.workStatus || 'Open';
            return {
                ...f,
                observation: [f.component, f.condition].filter(Boolean).join(' – ') || 'Finding',
                urgencyClass: `sev-pill ${TONES[f.urgency] || 'light'}`,
                cardClass: `finding ${status === 'Done' ? 'done' : status === 'Needs Follow-up' ? 'follow' : ''}`,
                beforePhotos: f.photos || [],
                afterThumbs: f.afterPhotos || [],
                noBefore: !(f.photos && f.photos.length > 0),
                busy: this.savingId === f.id,
                noteValue: this.notes[f.id] !== undefined ? this.notes[f.id] : f.workNote || '',
                readingValue: this.readings[f.id] !== undefined ? this.readings[f.id] : f.reading || '',
                statuses: STATUSES.map((s) => ({
                    ...s,
                    cls: `status-btn ${s.tone}${status === s.value ? ' selected' : ''}`,
                    ariaPressed: status === s.value ? 'true' : 'false'
                }))
            };
        });
    }

    handleStepReading(event) {
        this.stepReadings = { ...this.stepReadings, [event.target.dataset.key]: event.target.value };
    }

    async toggleStep(event) {
        const key = event.currentTarget.dataset.key;
        const step = this.state.steps.find((s) => s.key === key);
        await this.persistStep(key, !step.done);
    }

    async saveStepReading(event) {
        const key = event.target.dataset.key;
        const step = this.state.steps.find((s) => s.key === key);
        if (this.stepReadings[key] === undefined || this.stepReadings[key] === (step.reading || '')) return;
        // A reading means the step was done.
        await this.persistStep(key, true);
    }

    async persistStep(key, done) {
        const step = this.state.steps.find((s) => s.key === key);
        const reading = this.stepReadings[key] !== undefined ? this.stepReadings[key] : step.reading;
        this.savingId = key;
        try {
            this.apply(await saveStep({ workOrderId: this.targetId, stepKey: key, done, reading }));
            const rest = { ...this.stepReadings };
            delete rest[key];
            this.stepReadings = rest;
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.savingId = undefined;
        }
    }

    handleNote(event) {
        this.notes = { ...this.notes, [event.target.dataset.id]: event.target.value };
    }

    handleReading(event) {
        this.readings = { ...this.readings, [event.target.dataset.id]: event.target.value };
    }

    async setStatus(event) {
        const { id, value } = event.currentTarget.dataset;
        const f = this.state.findings.find((x) => x.id === id);
        const current = f.workStatus || 'Open';
        await this.persistFinding(id, current === value ? 'Open' : value);
    }

    async saveNote(event) {
        const id = event.currentTarget.dataset.id;
        const f = this.state.findings.find((x) => x.id === id);
        await this.persistFinding(id, f.workStatus);
    }

    async persistFinding(id, status) {
        const f = this.state.findings.find((x) => x.id === id);
        const note = this.notes[id] !== undefined ? this.notes[id] : f.workNote;
        const reading = this.readings[id] !== undefined ? this.readings[id] : null;
        this.savingId = id;
        try {
            this.apply(await saveWork({ workOrderId: this.targetId, findingId: id, status, note, reading }));
            const notes = { ...this.notes };
            delete notes[id];
            this.notes = notes;
            const readings = { ...this.readings };
            delete readings[id];
            this.readings = readings;
        } catch (e) {
            this.error = this.message(e);
        } finally {
            this.savingId = undefined;
        }
    }

    async handleAfterUpload() {
        try {
            this.apply(await getWorkOrderFindings({ workOrderId: this.targetId }));
        } catch (e) {
            this.error = this.message(e);
        }
    }

    previewPhoto(event) {
        const { url, title } = event.currentTarget.dataset;
        this.viewing = { url, title };
    }

    closePhoto() {
        this.viewing = undefined;
    }
}
