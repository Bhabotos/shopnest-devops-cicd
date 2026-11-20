import { useState } from 'react';
import { placeOrder } from '../api.js';

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function validateCustomer({ name, email, address }) {
  const errors = {};
  if (!name.trim()) errors.name = 'Name is required';
  if (!EMAIL_PATTERN.test(email.trim())) errors.email = 'Enter a valid email address';
  if (address.trim().length < 5) errors.address = 'Address must be at least 5 characters';
  return errors;
}

export default function CheckoutForm({ lines, onPlaced, onBack }) {
  const [values, setValues] = useState({ name: '', email: '', address: '' });
  const [errors, setErrors] = useState({});
  const [submitError, setSubmitError] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const update = (field) => (e) => setValues((v) => ({ ...v, [field]: e.target.value }));

  async function handleSubmit(e) {
    e.preventDefault();
    const found = validateCustomer(values);
    setErrors(found);
    setSubmitError('');
    if (Object.keys(found).length > 0) return;

    setSubmitting(true);
    try {
      const order = await placeOrder({
        customer: {
          name: values.name.trim(),
          email: values.email.trim(),
          address: values.address.trim(),
        },
        items: lines.map((l) => ({ productId: l.product.id, quantity: l.quantity })),
      });
      onPlaced(order);
    } catch (err) {
      setSubmitError(err.message);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} noValidate>
      <h2>Checkout</h2>
      <label>
        Name
        <input value={values.name} onChange={update('name')} />
      </label>
      {errors.name && <p role="alert">{errors.name}</p>}
      <label>
        Email
        <input type="email" value={values.email} onChange={update('email')} />
      </label>
      {errors.email && <p role="alert">{errors.email}</p>}
      <label>
        Shipping address
        <textarea value={values.address} onChange={update('address')} />
      </label>
      {errors.address && <p role="alert">{errors.address}</p>}
      {submitError && <p role="alert">{submitError}</p>}
      <button type="button" onClick={onBack}>Back to cart</button>
      <button type="submit" disabled={submitting}>
        {submitting ? 'Placing order...' : 'Place order'}
      </button>
    </form>
  );
}
