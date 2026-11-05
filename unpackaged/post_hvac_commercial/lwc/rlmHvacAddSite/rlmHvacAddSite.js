import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import getState from '@salesforce/apex/RLM_HVAC_ContractAmend.state';
import addSite from '@salesforce/apex/RLM_HVAC_ContractAmend.addSite';

const formatDate = (iso) =>
    iso ? new Date(`${iso}T00:00:00Z`).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }) : '';

/** Adds a property group's uncovered site to its running contract, co-terminated with the contract. */
export default class RlmHvacAddSite extends NavigationMixin(LightningElement) {
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
    effectiveDate;
    busy = false;
    error;
    result;

    async load() {
        try {
            this.state = await getState({ recordId: this._recordId });
            this.effectiveDate = this.state.effectiveDate;
            const candidates = this.state.candidates || [];
            const own = candidates.find((c) => c.accountId === this._recordId);
            this.selectedId = own ? own.accountId : candidates.length ? candidates[0].accountId : undefined;
            this.error = undefined;
        } catch (e) {
            this.error = this.message(e, 'Could not load the contract.');
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    get ready() {
        return !!this.state && this.state.hasContract && !this.result;
    }

    get noContract() {
        return !!this.state && !this.state.hasContract;
    }

    get noCandidates() {
        return this.ready && !(this.state.candidates || []).length;
    }

    get candidates() {
        return (this.state.candidates || []).map((c) => {
            const selected = c.accountId === this.selectedId;
            return {
                ...c,
                selected,
                cls: `candidate${selected ? ' selected' : ''}`,
                pressed: selected ? 'true' : 'false',
                summary: `${c.site.siteType || 'Site'} · ${c.site.unitCount} rooftop units · ${this.tons(c.site.tons)} tons`,
                lines: c.site.lines.map((l) => ({
                    key: l.sku,
                    name: l.name,
                    detail: l.units ? `${l.quantity} × ${l.units}` : `${l.quantity}`,
                    amount: l.unitPrice * l.quantity
                }))
            };
        });
    }

    get selected() {
        return this.candidates.find((c) => c.selected);
    }

    get months() {
        if (!this.effectiveDate || !this.state.contractEnd) return 0;
        const [ey, em, ed] = this.effectiveDate.split('-').map(Number);
        const [cy, cm] = this.state.contractEnd.split('-').map(Number);
        return (cy - ey) * 12 + (cm - em) + (ed === 1 ? 1 : 0);
    }

    get termText() {
        const m = this.months;
        return `${m} month${m === 1 ? '' : 's'} to the contract end${this.isMidMonth ? ', plus a prorated first month' : ''}`;
    }

    get isMidMonth() {
        return !!this.effectiveDate && !this.effectiveDate.endsWith('-01');
    }

    get termValue() {
        const site = this.selected;
        return site ? site.site.monthly * this.months : 0;
    }

    get introText() {
        const s = this.state;
        const po = s.poNumber ? ` under PO ${s.poNumber}` : '';
        const d = s.discountPercent;
        const pricing = d ? `Priced at the contract's ${Number(d)}% discount.` : 'Priced at contract rates.';
        return `The contract runs ${formatDate(s.contractStart)} to ${formatDate(s.contractEnd)} for ${s.coveredSites} sites${po}. `
            + `The new site co-terminates with it. ${pricing}`;
    }

    get addDisabled() {
        return this.busy || !this.selectedId || !this.effectiveDate;
    }

    tons(value) {
        return Number(value || 0).toLocaleString(undefined, { maximumFractionDigits: 1 });
    }

    choose(event) {
        this.selectedId = event.currentTarget.dataset.id;
    }

    changeDate(event) {
        this.effectiveDate = event.target.value;
    }

    async add() {
        this.busy = true;
        this.error = undefined;
        try {
            this.result = await addSite({ siteId: this.selectedId, effectiveDate: this.effectiveDate });
        } catch (e) {
            this.error = this.message(e, 'Could not add the site.');
        } finally {
            this.busy = false;
        }
    }

    openOrder() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.result.orderId, objectApiName: 'Order', actionName: 'view' }
        });
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}
