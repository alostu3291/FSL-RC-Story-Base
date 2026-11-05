import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import getState from '@salesforce/apex/RLM_HVAC_RefrigerantCompliance.state';
import logRefrigerant from '@salesforce/apex/RLM_HVAC_RefrigerantCompliance.logRefrigerant';

const formatDate = (iso) =>
    iso ? new Date(`${String(iso).slice(0, 10)}T00:00:00Z`).toLocaleDateString(undefined, {
        month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC'
    }) : '';
const lb = (n) => `${Number(n)} lb`;

/**
 * Refrigerant log for a site's rooftop units: on a work order the technician picks a unit and logs the
 * pounds added; on an asset it shows that unit's leak rate, compliance and history.
 */
export default class RlmHvacRefrigerantLog extends LightningElement {
    @api objectApiName;

    // Quick actions can set recordId after connectedCallback, so load from the setter too.
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
    state;
    selectedId;
    showAll = false;
    pounds = '';
    notes = '';
    busy = false;
    error;
    result;

    async load() {
        try {
            this.state = await getState({ recordId: this._recordId });
            if (this.state.singleUnit && this.state.units.length) this.selectedId = this.state.units[0].assetId;
            this.error = undefined;
        } catch (e) {
            this.error = this.message(e, 'Could not load the units.');
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    get isAction() {
        return this.objectApiName === 'WorkOrder' || String(this._recordId || '').startsWith('0WO');
    }

    get limitText() {
        return `Units holding 50 lb or more are tracked. Over ${Number(this.state.leakLimit)}% a year needs a repair within 30 days.`;
    }

    decorate(u) {
        let pill = 'Not tracked';
        let pillCls = 'pill';
        if (u.tracked) {
            pill = u.status === 'Leak Repair Due' ? 'Repair due' : 'In compliance';
            pillCls = u.status === 'Leak Repair Due' ? 'pill hot' : 'pill ok';
        }
        const rate = u.leakRate == null ? '' : ` · ${Number(u.leakRate)}% a year`;
        return {
            ...u,
            key: u.assetId,
            pill,
            pillCls,
            meta: `${lb(u.charge)} ${u.refrigerant || ''} · ${Number(u.tons)} tons${rate}`,
            cls: `unit${u.assetId === this.selectedId ? ' selected' : ''}`
        };
    }

    get units() {
        const all = (this.state.units || []).filter((u) => this.showAll || u.tracked);
        return all.map((u) => this.decorate(u));
    }

    get hiddenCount() {
        return (this.state.units || []).filter((u) => !u.tracked).length;
    }

    get showBack() {
        return !this.state.singleUnit;
    }

    get showToggle() {
        return !this.state.singleUnit && this.hiddenCount > 0;
    }

    get toggleLabel() {
        return this.showAll ? 'Show tracked units only' : `Show all units (${this.hiddenCount} more)`;
    }

    get selected() {
        const u = (this.state.units || []).find((x) => x.assetId === this.selectedId);
        return u ? this.decorate(u) : undefined;
    }

    get selectedSummary() {
        const u = this.selected;
        const parts = [`${lb(u.charge)} of ${u.refrigerant}`, u.model];
        if (u.lastAdded) parts.push(`last added ${formatDate(u.lastAdded)}`);
        return parts.filter(Boolean).join(' · ');
    }

    get repairText() {
        const u = this.selected;
        if (!u || u.status !== 'Leak Repair Due') return '';
        const wo = u.repairWorkOrderNumber ? `Leak repair work order ${u.repairWorkOrderNumber}` : 'Leak repair';
        return `${wo} is due by ${formatDate(u.repairDue)}.`;
    }

    get history() {
        return (this.selected.logs || []).slice(0, 5).map((l) => ({
            ...l,
            key: l.logId,
            when: formatDate(l.loggedOn),
            what: `${lb(l.pounds)} added${l.technician ? ` by ${l.technician}` : ''}`,
            rate: l.leakRate == null ? '' : `${Number(l.leakRate)}%`,
            rateCls: l.overLimit ? 'rate hot' : 'rate'
        }));
    }

    get hasHistory() {
        return !!this.selected && this.selected.logs && this.selected.logs.length > 0;
    }

    get canLog() {
        return this.isAction || !!this.selected;
    }

    get logDisabled() {
        return this.busy || !(Number(this.pounds) > 0);
    }

    get resultText() {
        const r = this.result;
        if (!r) return '';
        const rate = `${r.tag} is leaking at ${Number(r.leakRate)}% a year over ${r.days} days.`;
        if (!r.tracked) return `${rate} It holds under 50 lb, so there's no leak rate limit.`;
        if (!r.overLimit) return `${rate} That's within the ${Number(this.state.leakLimit)}% limit.`;
        return `${rate} That's over the ${Number(this.state.leakLimit)}% limit: leak repair work order `
            + `${r.repairWorkOrderNumber} is open, due by ${formatDate(r.repairDue)}.`;
    }

    get resultCls() {
        return this.result && this.result.overLimit ? 'result hot' : 'result ok';
    }

    pick(event) {
        this.selectedId = event.currentTarget.dataset.id;
        this.result = undefined;
        this.pounds = '';
        this.notes = '';
    }

    back() {
        this.selectedId = undefined;
        this.result = undefined;
    }

    toggleAll() {
        this.showAll = !this.showAll;
    }

    changePounds(event) {
        this.pounds = event.target.value;
    }

    changeNotes(event) {
        this.notes = event.target.value;
    }

    async log() {
        this.busy = true;
        this.error = undefined;
        try {
            const r = await logRefrigerant({
                recordId: this._recordId,
                assetId: this.selectedId,
                pounds: Number(this.pounds),
                notes: this.notes
            });
            this.state = r.state;
            this.result = r;
            this.pounds = '';
            this.notes = '';
        } catch (e) {
            this.error = this.message(e, 'Could not log the refrigerant.');
        } finally {
            this.busy = false;
        }
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}
