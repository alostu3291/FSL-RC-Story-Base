import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import getProposal from '@salesforce/apex/RLM_HVAC_CapitalProject.proposal';
import createQuote from '@salesforce/apex/RLM_HVAC_CapitalProject.createQuote';

const USD = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });

/** Quotes replacing a site's aging rooftop units, billed 40% at booking, 40% at install and 20% at commissioning. */
export default class RlmHvacCapitalProject extends NavigationMixin(LightningElement) {
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
    proposal;
    selected = new Set();
    busy = false;
    error;
    quoteId;

    async load(siteId) {
        this.busy = true;
        try {
            this.proposal = await getProposal({ recordId: this._recordId, siteId: siteId || null });
            this.selected = new Set(this.proposal.units.filter((u) => u.recommended).map((u) => u.assetId));
            this.error = undefined;
        } catch (e) {
            this.error = this.message(e, 'Could not load the site.');
        } finally {
            this.busy = false;
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    get siteOptions() {
        return (this.proposal.sites || []).map((s) => ({
            label: s.recommended ? `${s.name} (${s.recommended} due)` : s.name,
            value: s.accountId
        }));
    }

    get hasUnits() {
        return !!this.proposal && this.proposal.units.length > 0;
    }

    get units() {
        return this.proposal.units.map((u) => ({
            ...u,
            key: u.assetId,
            checked: this.selected.has(u.assetId),
            disabled: !u.eligible || !!this.proposal.openQuoteId || !!this.quoteId,
            detail: `${Number(u.tons)} tons · ${u.refrigerant || 'refrigerant unknown'} · installed ${u.installYear || 'unknown'}`,
            cls: `unit${u.recommended ? ' due' : ''}${u.eligible ? '' : ' muted'}`
        }));
    }

    get count() {
        return this.selected.size;
    }

    get unitsTotal() {
        return this.count * (this.proposal.unitPrice || 0);
    }

    get total() {
        return this.count ? this.unitsTotal + (this.proposal.cranePrice || 0) : 0;
    }

    get unitsText() {
        return `${this.count} × ${USD.format(this.proposal.unitPrice || 0)} rooftop unit, 10 tons, R-454B`;
    }

    get milestones() {
        return this.proposal.milestones.map((m) => ({
            ...m,
            key: m.name,
            label: `${m.name} (${Number(m.percent)}%)`,
            value: Math.round(this.total * Number(m.percent)) / 100
        }));
    }

    get introText() {
        const due = this.proposal.units.filter((u) => u.recommended).length;
        return due
            ? `${due} of ${this.proposal.units.length} rooftop units here are on R-22 or past 15 years. `
                + 'Replacing them takes a crane day, the install and commissioning.'
            : 'No units here are due for replacement. Pick any 10-ton unit to quote it.';
    }

    get hasOpenQuote() {
        return !!this.proposal && (!!this.proposal.openQuoteId || !!this.quoteId);
    }

    get createDisabled() {
        return !this.proposal || this.count === 0 || this.busy;
    }

    get closeLabel() {
        return this.hasOpenQuote ? 'Close' : 'Cancel';
    }

    changeSite(event) {
        this.quoteId = undefined;
        this.load(event.detail.value);
    }

    toggle(event) {
        const id = event.target.dataset.id;
        const next = new Set(this.selected);
        if (event.target.checked) next.add(id);
        else next.delete(id);
        this.selected = next;
    }

    async create() {
        this.busy = true;
        this.error = undefined;
        try {
            this.quoteId = await createQuote({ siteId: this.proposal.siteId, unitIds: [...this.selected] });
        } catch (e) {
            this.error = this.message(e, 'Could not create the project quote.');
        } finally {
            this.busy = false;
        }
    }

    openQuote() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.quoteId || this.proposal.openQuoteId, objectApiName: 'Quote', actionName: 'view' }
        });
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}
