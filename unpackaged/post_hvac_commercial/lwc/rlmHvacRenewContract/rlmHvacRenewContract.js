import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import getState from '@salesforce/apex/RLM_HVAC_ContractRenew.state';
import renew from '@salesforce/apex/RLM_HVAC_ContractRenew.renew';

const USD = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const formatDate = (iso) =>
    iso ? new Date(`${iso}T00:00:00Z`).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' }) : '';

/** Creates the property group's renewal quote: every site for another year at the annual increase. */
export default class RlmHvacRenewContract extends NavigationMixin(LightningElement) {
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
    busy = false;
    error;
    created = false;

    async load() {
        try {
            this.state = await getState({ recordId: this._recordId });
            this.error = undefined;
        } catch (e) {
            this.error = this.message(e, 'Could not load the contract.');
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    get noContract() {
        return !!this.state && !this.state.hasContract;
    }

    get hasQuote() {
        return !!this.state && !!this.state.renewalQuoteId;
    }

    get canRenew() {
        return !!this.state && this.state.hasContract && !this.state.renewalQuoteId;
    }

    get closeLabel() {
        return this.canRenew ? 'Cancel' : 'Close';
    }

    get introText() {
        const s = this.state;
        return `The contract ends ${formatDate(s.contractEnd)}. The renewal runs another 12 months from `
            + `${formatDate(s.renewalStart)}, with each site at this year's price plus the `
            + `${Number(s.upliftPercent)}% annual increase.`;
    }

    get increaseText() {
        const s = this.state;
        return `Renewal year, up ${USD.format(s.renewalMonthly - s.currentMonthly)} a month`;
    }

    get sites() {
        return (this.state.sites || []).map((s) => ({ ...s, key: s.accountId }));
    }

    async createRenewal() {
        this.busy = true;
        this.error = undefined;
        try {
            this.state = await renew({ recordId: this._recordId });
            this.created = true;
        } catch (e) {
            this.error = this.message(e, 'Could not create the renewal quote.');
        } finally {
            this.busy = false;
        }
    }

    openQuote() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.state.renewalQuoteId, objectApiName: 'Quote', actionName: 'view' }
        });
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}
