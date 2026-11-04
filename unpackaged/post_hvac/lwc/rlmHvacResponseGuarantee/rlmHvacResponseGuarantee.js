import { LightningElement, api } from 'lwc';

const MINUTE = 60 * 1000;
const DUE_SOON_MINUTES = 2 * 60;

function duration(ms) {
    const minutes = Math.max(0, Math.round(ms / MINUTE));
    const days = Math.floor(minutes / 1440);
    const hours = Math.floor((minutes % 1440) / 60);
    const mins = minutes % 60;
    if (days) return `${days}d ${hours}h`;
    if (hours) return `${hours}h ${mins}m`;
    return `${mins}m`;
}

function when(value) {
    return new Date(value).toLocaleString('en-US', {
        weekday: 'short',
        hour: 'numeric',
        minute: '2-digit'
    });
}

/** Countdown to a covered service call's priority response, from its Priority Response milestone. */
export default class RlmHvacResponseGuarantee extends LightningElement {
    @api response;
    now = Date.now();
    _timer;

    connectedCallback() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timer = setInterval(() => {
            this.now = Date.now();
        }, 30 * 1000);
    }

    disconnectedCallback() {
        clearInterval(this._timer);
    }

    get due() {
        return new Date(this.response.dueBy).getTime();
    }
    get met() {
        return !!this.response.metAt;
    }
    get remaining() {
        return this.due - this.now;
    }
    get state() {
        if (this.met) return this.response.violated ? 'late' : 'met';
        if (this.remaining <= 0) return 'overdue';
        return this.remaining <= DUE_SOON_MINUTES * MINUTE ? 'soon' : 'ontrack';
    }

    get cardClass() {
        return `card ${this.state}`;
    }
    get title() {
        const issue = this.response.reportedIssue ? ` · ${this.response.reportedIssue}` : '';
        return `Priority response${issue}`;
    }
    get subtitle() {
        const window = this.response.responseHours ? `${this.response.responseHours}-hour response` : 'Covered service call';
        return this.response.agreementName ? `${window} · ${this.response.agreementName}` : window;
    }
    get headline() {
        switch (this.state) {
            case 'met':
                return 'Response window met';
            case 'late':
                return 'Arrived after the response window';
            case 'overdue':
                return `Overdue by ${duration(-this.remaining)}`;
            default:
                return `${duration(this.remaining)} left`;
        }
    }
    get detail() {
        if (this.met) {
            const margin = this.due - new Date(this.response.metAt).getTime();
            const spare = margin > 0 ? `, ${duration(margin)} to spare` : '';
            return `Arrived ${when(this.response.metAt)}${spare}. Deadline was ${when(this.response.dueBy)}.`;
        }
        const hours = this.response.responseHours ? `${this.response.responseHours} service hours, 7 AM to 9 PM` : 'service hours, 7 AM to 9 PM';
        return `Arrive by ${when(this.response.dueBy)}. Called ${when(this.response.requestedAt)}; ${hours}.`;
    }
    get showBar() {
        return !this.met;
    }
    get barStyle() {
        const start = new Date(this.response.requestedAt).getTime();
        const span = Math.max(1, this.due - start);
        const used = Math.min(100, Math.max(0, ((this.now - start) / span) * 100));
        return `width: ${used.toFixed(1)}%`;
    }
}
