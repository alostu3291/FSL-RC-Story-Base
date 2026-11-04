import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import getReplacementOptions from '@salesforce/apex/RLM_HVAC_FieldVisit.getReplacementOptions';
import createReplacementQuote from '@salesforce/apex/RLM_HVAC_FieldVisit.createReplacementQuote';

const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });

/** Good / better / best replacement systems for the home, and a replacement quote for the one picked. */
export default class RlmHvacReplacementOptions extends NavigationMixin(LightningElement) {
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
    data;
    selected;
    busy = false;
    error;

    async load() {
        try {
            this.data = await getReplacementOptions({ recordId: this._recordId });
            const suggested = this.data.options.find((o) => o.suggested);
            this.selected = this.data.chosenSku || (suggested ? suggested.sku : this.data.options[0].sku);
            this.error = undefined;
        } catch (e) {
            this.error = this.message(e, 'Could not load the replacement options.');
        }
    }

    message(e, fallback) {
        return (e && e.body && e.body.message) || (e && e.message) || fallback;
    }

    get quoted() {
        return !!(this.data && this.data.quoteId);
    }

    get options() {
        return this.data.options.map((o) => {
            const isSelected = o.sku === this.selected;
            return {
                ...o,
                priceLabel: money.format(o.price),
                cardClass: `option${isSelected ? ' selected' : ''}${this.quoted && !isSelected ? ' faded' : ''}`,
                ariaPressed: isSelected ? 'true' : 'false',
                featureItems: (o.features || []).map((text, i) => ({ key: `${o.sku}-${i}`, text })),
                badge: this.quoted && isSelected ? 'Quoted' : o.suggested ? 'Most popular' : null
            };
        });
    }

    get selectedOption() {
        return this.data && this.data.options.find((o) => o.sku === this.selected);
    }

    get quoteLabel() {
        const o = this.selectedOption;
        return o ? `Quote the ${o.tier.toLowerCase()} system · ${money.format(o.price)}` : 'Quote the replacement';
    }

    get zoneLine() {
        return this.data.zoneCode ? `Installed prices for ${this.data.zoneCode}` : 'Installed prices';
    }

    choose(event) {
        if (this.quoted) return;
        this.selected = event.currentTarget.dataset.sku;
    }

    async quote() {
        this.busy = true;
        this.error = undefined;
        try {
            const result = await createReplacementQuote({ recordId: this._recordId, sku: this.selected });
            this.data = { ...this.data, quoteId: result.quoteId, quoteNumber: result.quoteNumber, chosenSku: this.selected };
        } catch (e) {
            this.error = this.message(e, 'Could not create the replacement quote.');
        } finally {
            this.busy = false;
        }
    }

    openQuote() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.data.quoteId, objectApiName: 'Quote', actionName: 'view' }
        });
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}
