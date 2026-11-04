import { LightningElement, api, wire } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import pricingFor from '@salesforce/apex/RLM_HVAC_FieldQuote.pricingFor';

const PLANS = [
    {
        sku: 'HVAC-BASIC',
        name: 'Comfort Basic',
        blurb: 'Two tune-ups a year for newer systems',
        features: ['Spring AC and fall furnace tune-ups', '24-hour priority response', '10% off repairs']
    },
    {
        sku: 'HVAC-PLUS',
        name: 'Comfort Plus',
        blurb: 'The usual pick for most homes',
        features: ['Two tune-ups a year', '8-hour priority response', 'No diagnostic fee', '15% off repairs']
    },
    {
        sku: 'HVAC-PREMIER',
        name: 'Comfort Premier',
        blurb: 'Covered parts and labor for aging equipment',
        features: ['Two tune-ups a year', '4-hour priority response', 'No diagnostic fee', 'Covered repairs']
    }
];

const REPAIRS = {
    'HVAC-COIL-CLEAN': 'Coil cleaning',
    'HVAC-CAPACITOR': 'Capacitor replacement',
    'HVAC-CONTACTOR': 'Contactor replacement',
    'HVAC-DRAIN-CLEAR': 'Condensate drain clear',
    'HVAC-REFRIGERANT': 'Refrigerant leak check and recharge',
    'HVAC-BLOWER-MOTOR': 'Blower motor replacement'
};

const money = (n) => {
    const v = Math.round(Number(n) * 100) / 100;
    return Number.isInteger(v) ? `$${v.toLocaleString()}` : `$${v.toFixed(2)}`;
};
const plusMoney = (n) => (n > 0 ? `+${money(n)}/mo` : 'No adjustment');

const SYSTEM_TYPES = [
    { value: 'AcFurnace', label: 'AC + furnace', icon: 'utility:home', hint: 'Split system, gas heat' },
    { value: 'HeatPump', label: 'Heat pump', icon: 'utility:refresh', hint: 'Heats and cools' },
    { value: 'Boiler', label: 'Boiler', icon: 'utility:flow', hint: 'Hot water heat' }
];

const AGE_BANDS = [
    { value: '0to5', label: '0–5 years', tone: 'light', hint: 'Newer equipment' },
    { value: '6to10', label: '6–10 years', tone: 'light', hint: 'Mid-life' },
    { value: '11to15', label: '11–15 years', tone: 'moderate', hint: 'Aging' },
    { value: 'Over15', label: '15+ years', tone: 'heavy', hint: 'Near end of life' }
];

const MAX_SYSTEMS = 4;

export default class RlmHvacAssessQuote extends LightningElement {
    @api accountName;
    @api postalCode;

    _planSku = 'HVAC-PLUS';
    _systemType = 'AcFurnace';
    _systemCount = 1;
    _equipmentAge = '6to10';
    _includeIaq = false;
    _includeWaterHeater = false;
    _repairSkus = [];
    _rec;
    _overrideNote = '';
    pricing;

    @wire(pricingFor, { postalCode: '$postalCode' })
    wiredPricing({ data }) {
        this.pricing = data;
    }

    zonePrice(sku) {
        const prices = this.pricing && this.pricing.zonePrices;
        return prices && prices[sku] !== undefined ? Number(prices[sku]) : null;
    }

    get ageAdjustment() {
        const map = this.pricing && this.pricing.ageAdjustments;
        return map ? Number(map[this._equipmentAge] || 0) : 0;
    }

    get hasPricing() {
        return this.zonePrice(this._planSku) !== null;
    }

    get breakdown() {
        const sku = this._planSku;
        const list = Number(this.pricing.listPrices[sku]);
        const zoned = this.zonePrice(sku);
        const zoneDelta = Math.round((zoned - list) * 100) / 100;
        const adjustment = this.ageAdjustment;
        const perSystem = zoned + adjustment;
        const planTotal = perSystem * this._systemCount;
        const addOns = [];
        if (this._includeIaq && this.zonePrice('HVAC-IAQ') !== null) {
            addOns.push({ key: 'iaq', label: 'Indoor air quality', amount: this.zonePrice('HVAC-IAQ') });
        }
        if (this._includeWaterHeater && this.zonePrice('HVAC-WATER-HEATER') !== null) {
            addOns.push({ key: 'wh', label: 'Water heater care', amount: this.zonePrice('HVAC-WATER-HEATER') });
        }
        const monthly = addOns.reduce((sum, a) => sum + a.amount, planTotal);
        const tuneUp = this.zonePrice('HVAC-TUNEUP');
        const repairs = this._repairSkus
            .filter((r) => this.zonePrice(r) !== null)
            .map((r) => ({ key: r, label: REPAIRS[r] || r, amount: this.zonePrice(r) }));
        const oneTime = repairs.reduce((sum, r) => sum + r.amount, tuneUp === null ? 0 : tuneUp * this._systemCount);
        const multiplier = Number(this.pricing.zoneMultiplier || 1);
        return {
            planName: this.selectedPlanName,
            list: money(list),
            zoneLabel: `${this.pricing.zoneName || 'Service zone'} ×${multiplier.toFixed(2)}`,
            zoneAmount: zoneDelta === 0 ? 'No change' : `${zoneDelta > 0 ? '+' : '−'}${money(Math.abs(zoneDelta))}`,
            ageLabel: this.ageBandLabel,
            ageAmount: plusMoney(adjustment),
            hasAdjustment: adjustment > 0,
            adjustment: money(adjustment),
            perSystem: money(perSystem),
            systemsLabel: this._systemCount === 1 ? '1 system' : `${this._systemCount} systems`,
            planTotal: money(planTotal),
            addOns: addOns.map((a) => ({ ...a, amount: `${money(a.amount)}/mo` })),
            hasAddOns: addOns.length > 0,
            monthly: money(monthly),
            tuneUp: tuneUp === null ? null : money(tuneUp * this._systemCount),
            repairs: repairs.map((r) => ({ ...r, amount: money(r.amount) })),
            hasRepairs: repairs.length > 0,
            oneTime: money(oneTime)
        };
    }

    @api
    get recommendationJson() {
        return this._rec ? JSON.stringify(this._rec) : undefined;
    }
    /** Seeds every choice from the system check; explicit inputs set alongside it carry the same values. */
    set recommendationJson(v) {
        try {
            this._rec = v ? JSON.parse(v) : undefined;
        } catch (e) {
            this._rec = undefined;
        }
        const rec = this._rec;
        if (!rec || !rec.planSku) return;
        this._planSku = rec.planSku;
        if (rec.systemType) this._systemType = rec.systemType;
        if (rec.systemCount) this._systemCount = Math.min(rec.systemCount, MAX_SYSTEMS);
        if (rec.equipmentAge) this._equipmentAge = rec.equipmentAge;
        this._includeIaq = rec.includeIaq === true;
        this._includeWaterHeater = rec.includeWaterHeater === true;
        this._repairSkus = rec.repairSkus ? [...rec.repairSkus] : [];
    }

    @api
    get overrideReason() {
        return this.composeOverride();
    }
    set overrideReason(v) {
        this._overrideNote = v || '';
    }

    @api
    get planSku() {
        return this._planSku;
    }
    set planSku(v) {
        if (v) this._planSku = v;
    }

    @api
    get systemType() {
        return this._systemType;
    }
    set systemType(v) {
        if (v) this._systemType = v;
    }

    @api
    get systemCount() {
        return this._systemCount;
    }
    set systemCount(v) {
        const n = parseInt(v, 10);
        if (n > 0) this._systemCount = Math.min(n, MAX_SYSTEMS);
    }

    @api
    get equipmentAge() {
        return this._equipmentAge;
    }
    set equipmentAge(v) {
        if (v) this._equipmentAge = v;
    }

    @api
    get includeIaq() {
        return this._includeIaq;
    }
    set includeIaq(v) {
        if (v !== undefined && v !== null) this._includeIaq = !!v;
    }

    @api
    get includeWaterHeater() {
        return this._includeWaterHeater;
    }
    set includeWaterHeater(v) {
        if (v !== undefined && v !== null) this._includeWaterHeater = !!v;
    }

    /** Comma-separated repair SKUs. */
    @api
    get repairSkus() {
        return this._repairSkus.join(',');
    }
    set repairSkus(v) {
        if (v !== undefined && v !== null) {
            this._repairSkus = String(v).split(',').map((s) => s.trim()).filter(Boolean);
        }
    }

    connectedCallback() {
        this.publishAll();
    }

    // ---------- recommendation from the system check ----------
    get hasAssessment() {
        return !!(this._rec && this._rec.planSku);
    }

    get recommendedSku() {
        return this.hasAssessment ? this._rec.planSku : 'HVAC-PLUS';
    }

    get recommendedRepairs() {
        return this.hasAssessment && this._rec.repairSkus ? this._rec.repairSkus : [];
    }

    reasonsFor(sku) {
        if (!this.hasAssessment || !this._rec.reasons) return [];
        const r = this._rec.reasons.find((x) => x.sku === sku);
        return r && r.because ? r.because.map((text, i) => ({ key: `${sku}-${i}`, text })) : [];
    }

    get iaqReasons() {
        return this.reasonsFor('HVAC-IAQ');
    }

    get waterHeaterReasons() {
        return this.reasonsFor('HVAC-WATER-HEATER');
    }

    get hasIaqReasons() {
        return this.iaqReasons.length > 0;
    }

    get hasWaterHeaterReasons() {
        return this.waterHeaterReasons.length > 0;
    }

    get planSubtitle() {
        return this.hasAssessment
            ? 'Pre-selected from the system check. You can still change it. Priced per system.'
            : 'Tap a card. Comfort Plus is the usual pick in Naperville. Priced per system.';
    }

    get ageFromAssessment() {
        if (!this.hasAssessment || this._rec.oldestAge === null || this._rec.oldestAge === undefined) return null;
        return `${this._rec.oldestAge} years`;
    }

    get replacementRecommended() {
        return this.hasAssessment && this._rec.replacementRecommended === true;
    }

    get safetyFlag() {
        return this.hasAssessment && this._rec.safetyFlag === true;
    }

    get changes() {
        if (!this.hasAssessment) return [];
        const rec = this._rec;
        const out = [];
        const name = (sku) => (PLANS.find((p) => p.sku === sku) || { name: sku }).name;
        if (this._planSku !== rec.planSku) out.push(`Agreement ${name(rec.planSku)} → ${name(this._planSku)}`);
        if (rec.equipmentAge && this._equipmentAge !== rec.equipmentAge) {
            const label = (v) => (AGE_BANDS.find((b) => b.value === v) || { label: v }).label;
            out.push(`Equipment age ${label(rec.equipmentAge)} → ${label(this._equipmentAge)}`);
        }
        if (this._includeIaq !== (rec.includeIaq === true)) {
            out.push(this._includeIaq ? 'Indoor air quality added' : 'Indoor air quality removed');
        }
        if (this._includeWaterHeater !== (rec.includeWaterHeater === true)) {
            out.push(this._includeWaterHeater ? 'Water heater care added' : 'Water heater care removed');
        }
        const dropped = this.recommendedRepairs.filter((r) => !this._repairSkus.includes(r));
        if (dropped.length) out.push(`Declined ${dropped.map((r) => REPAIRS[r] || r).join(', ')}`);
        return out;
    }

    get isOverridden() {
        return this.changes.length > 0;
    }

    get changeSummary() {
        return this.changes.join(' · ');
    }

    get overrideNote() {
        return this._overrideNote;
    }

    composeOverride() {
        if (!this.isOverridden) return null;
        return `${this.changeSummary}. Reason: ${this._overrideNote || ''}`.trim();
    }

    handleOverride(event) {
        this._overrideNote = event.target.value;
        this.emit('overrideReason', this.composeOverride());
    }

    get plans() {
        const recSku = this.recommendedSku;
        return PLANS.map((p) => ({
            ...p,
            recommended: p.sku === recSku,
            because: this.reasonsFor(p.sku),
            hasBecause: p.sku === recSku && this.reasonsFor(p.sku).length > 0,
            selected: p.sku === this._planSku,
            cardClass: p.sku === this._planSku ? 'plan-card selected' : 'plan-card',
            priceLabel: this.zonePrice(p.sku) === null ? '' : money(this.zonePrice(p.sku)),
            hasPrice: this.zonePrice(p.sku) !== null,
            ariaPressed: p.sku === this._planSku ? 'true' : 'false'
        }));
    }

    get systemTypes() {
        return SYSTEM_TYPES.map((p) => ({
            ...p,
            tileClass: p.value === this._systemType ? 'prop-tile selected' : 'prop-tile',
            ariaPressed: p.value === this._systemType ? 'true' : 'false'
        }));
    }

    get ageBands() {
        const map = this.pricing && this.pricing.ageAdjustments;
        return AGE_BANDS.map((s) => ({
            ...s,
            adjustment: map ? plusMoney(Number(map[s.value] || 0)) : '',
            chipClass: s.value === this._equipmentAge ? `sev-chip ${s.tone} selected` : `sev-chip ${s.tone}`,
            ariaPressed: s.value === this._equipmentAge ? 'true' : 'false'
        }));
    }

    get repairOptions() {
        const skus = [...new Set([...this.recommendedRepairs, ...this._repairSkus])];
        return skus.map((sku) => {
            const on = this._repairSkus.includes(sku);
            const price = this.zonePrice(sku);
            return {
                sku,
                label: REPAIRS[sku] || sku,
                price: price === null ? '' : money(price),
                because: this.reasonsFor(sku),
                hasBecause: this.reasonsFor(sku).length > 0,
                cardClass: on ? 'addon-card on' : 'addon-card',
                ariaPressed: on ? 'true' : 'false'
            };
        });
    }

    get hasRepairOptions() {
        return this.repairOptions.length > 0;
    }

    get ageBandLabel() {
        const band = AGE_BANDS.find((b) => b.value === this._equipmentAge);
        return band ? band.label : '';
    }

    get systemCountLabel() {
        return this._systemCount === 1 ? '1 system' : `${this._systemCount} systems`;
    }

    get cannotRemoveSystem() {
        return this._systemCount <= 1;
    }

    get cannotAddSystem() {
        return this._systemCount >= MAX_SYSTEMS;
    }

    get iaqCardClass() {
        return this._includeIaq ? 'addon-card on' : 'addon-card';
    }

    get waterHeaterCardClass() {
        return this._includeWaterHeater ? 'addon-card on' : 'addon-card';
    }

    get iaqPrice() {
        const p = this.zonePrice('HVAC-IAQ');
        return p === null ? '' : `${money(p)}/mo`;
    }

    get waterHeaterPrice() {
        const p = this.zonePrice('HVAC-WATER-HEATER');
        return p === null ? '' : `${money(p)}/mo`;
    }

    get selectedPlanName() {
        const plan = PLANS.find((p) => p.sku === this._planSku);
        return plan ? plan.name : '';
    }

    get summaryBits() {
        const type = SYSTEM_TYPES.find((t) => t.value === this._systemType);
        const bits = [this.selectedPlanName, this.systemCountLabel, type && type.label, this.ageBandLabel];
        if (this._includeIaq) bits.push('Indoor air quality');
        if (this._includeWaterHeater) bits.push('Water heater care');
        if (this._repairSkus.length) bits.push(`${this._repairSkus.length} repair${this._repairSkus.length === 1 ? '' : 's'}`);
        return bits.filter(Boolean).join(' · ');
    }

    get hasZip() {
        return !!this.postalCode;
    }

    selectPlan(event) {
        this._planSku = event.currentTarget.dataset.sku;
        this.emit('planSku', this._planSku);
    }

    selectSystemType(event) {
        this._systemType = event.currentTarget.dataset.value;
        this.emit('systemType', this._systemType);
    }

    addSystem() {
        if (this._systemCount < MAX_SYSTEMS) {
            this._systemCount += 1;
            this.emit('systemCount', this._systemCount);
        }
    }

    removeSystem() {
        if (this._systemCount > 1) {
            this._systemCount -= 1;
            this.emit('systemCount', this._systemCount);
        }
    }

    selectAge(event) {
        this._equipmentAge = event.currentTarget.dataset.value;
        this.emit('equipmentAge', this._equipmentAge);
    }

    toggleIaq() {
        this._includeIaq = !this._includeIaq;
        this.emit('includeIaq', this._includeIaq);
    }

    toggleWaterHeater() {
        this._includeWaterHeater = !this._includeWaterHeater;
        this.emit('includeWaterHeater', this._includeWaterHeater);
    }

    toggleRepair(event) {
        const sku = event.currentTarget.dataset.sku;
        this._repairSkus = this._repairSkus.includes(sku)
            ? this._repairSkus.filter((r) => r !== sku)
            : [...this._repairSkus, sku];
        this.emit('repairSkus', this.repairSkus);
    }

    emit(name, value) {
        this.dispatchEvent(new FlowAttributeChangeEvent(name, value));
        if (name !== 'overrideReason') {
            this.dispatchEvent(new FlowAttributeChangeEvent('overrideReason', this.composeOverride()));
        }
    }

    publishAll() {
        this.emit('planSku', this._planSku);
        this.emit('systemType', this._systemType);
        this.emit('systemCount', this._systemCount);
        this.emit('equipmentAge', this._equipmentAge);
        this.emit('includeIaq', this._includeIaq);
        this.emit('includeWaterHeater', this._includeWaterHeater);
        this.emit('repairSkus', this.repairSkus);
    }

    @api
    validate() {
        if (!this._planSku || !this._systemType || !this._equipmentAge) {
            return {
                isValid: false,
                errorMessage: 'Complete each section before creating the quote.'
            };
        }
        if (this.isOverridden && !(this._overrideNote || '').trim()) {
            return {
                isValid: false,
                errorMessage: 'You changed the system check recommendation. Add a reason before creating the quote.'
            };
        }
        return { isValid: true };
    }
}
