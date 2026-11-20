import { useEffect, useId, useState } from 'react';

const WHOLE_NUMBER = /^\d+$/;

// Keeps what the user is typing (the draft) separate from the committed quantity, so clearing
// the box to retype never changes the cart. Only a whole number is committed, clamped to 1..max.
export default function QuantityInput({ label, value, max, onChange }) {
  const hintId = useId();
  const [draft, setDraft] = useState(String(value));
  const [hint, setHint] = useState('');

  useEffect(() => {
    setDraft(String(value));
  }, [value]);

  function handleChange(e) {
    const raw = e.target.value;
    setDraft(raw);

    if (raw === '') {
      setHint('');
      return;
    }
    if (!WHOLE_NUMBER.test(raw)) {
      setHint('Enter a whole number');
      return;
    }

    const requested = Number(raw);
    const clamped = Math.min(Math.max(requested, 1), max);
    setHint(requested > max ? `Only ${max} available` : requested < 1 ? 'Minimum quantity is 1' : '');
    setDraft(String(clamped));
    onChange(clamped);
  }

  function handleBlur() {
    if (!WHOLE_NUMBER.test(draft)) {
      setDraft(String(value));
      setHint('');
    }
  }

  return (
    <>
      <label>
        {label}
        <input
          type="number"
          inputMode="numeric"
          min="1"
          max={max}
          step="1"
          value={draft}
          onChange={handleChange}
          onBlur={handleBlur}
          aria-describedby={hint ? hintId : undefined}
        />
      </label>
      {hint && (
        <p id={hintId} role="status">
          {hint}
        </p>
      )}
    </>
  );
}
