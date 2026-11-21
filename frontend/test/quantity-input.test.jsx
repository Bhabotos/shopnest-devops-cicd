import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useReducer } from 'react';
import { describe, expect, it } from 'vitest';
import { cartReducer } from '../src/cart.js';
import Cart from '../src/components/Cart.jsx';

// These tests drive the real Cart and QuantityInput components with a real reducer, so "committed
// quantity" means what the cart state actually holds. The harness prints that state in an <output>
// element, because what the user sees in the box (the draft) can differ from what is committed.

const product = (overrides = {}) => ({
  id: 1,
  sku: 'nest-tee',
  name: 'Nest Tee',
  description: 'Soft tee.',
  price: { amountMinor: 79900, currency: 'BDT' },
  imageUrl: '/images/nest-tee.svg',
  stock: 10,
  ...overrides,
});

function CartHarness({ initialLines }) {
  const [lines, dispatch] = useReducer(cartReducer, initialLines);
  return (
    <>
      <Cart lines={lines} dispatch={dispatch} onBack={() => {}} onCheckout={() => {}} />
      <output data-testid="committed">{lines.map((l) => `${l.product.id}:${l.quantity}`).join(',')}</output>
    </>
  );
}

// Renders a cart holding one line and returns the quantity box and the committed state.
function renderOneLine({ stock = 10, quantity = 2, ...rest } = {}) {
  const p = product({ stock, ...rest });
  render(<CartHarness initialLines={[{ product: p, quantity }]} />);
  return {
    field: screen.getByLabelText(`Quantity for ${p.name}`),
    committed: () => screen.getByTestId('committed').textContent,
    name: p.name,
  };
}

describe('QuantityInput inside the cart', () => {
  it('F1: clearing the field does not remove the line or change the quantity', async () => {
    const { field, committed, name } = renderOneLine({ quantity: 2 });

    await userEvent.clear(field);

    expect(field).toHaveValue(null); // the box is empty while the user retypes
    expect(screen.getByText(name)).toBeInTheDocument(); // the line is still there
    expect(committed()).toBe('1:2'); // and the cart still holds 2
    // An empty box is not an error: no message is shown while the user is about to type.
    expect(screen.queryByText('Enter a whole number')).not.toBeInTheDocument();
  });

  it('F2: clearing and typing 3 commits 3', async () => {
    const { field, committed } = renderOneLine({ quantity: 2 });

    await userEvent.clear(field);
    await userEvent.type(field, '3');

    expect(committed()).toBe('1:3');
  });

  it('F3: a value above the stock is clamped and explained', async () => {
    const { field, committed } = renderOneLine({ stock: 5, quantity: 2 });

    await userEvent.clear(field);
    await userEvent.type(field, '9');

    expect(committed()).toBe('1:5');
    expect(screen.getByText('Only 5 available')).toBeVisible();
  });

  // The committed number is clamped by the cart, but the box itself must show the clamped number too.
  // When the cart already holds that number nothing re-renders the box, so the component has to do it.
  it('F3/F5 (box): the box shows the clamped number even when the cart already holds it', async () => {
    const atMax = renderOneLine({ stock: 5, quantity: 5 });
    await userEvent.clear(atMax.field);
    await userEvent.type(atMax.field, '9');
    expect(atMax.committed()).toBe('1:5');
    expect(atMax.field).toHaveValue(5);
  });

  it('F5 (box): typing 0 shows 1 in the box when the cart already holds 1', async () => {
    const atMin = renderOneLine({ stock: 5, quantity: 1 });
    await userEvent.clear(atMin.field);
    await userEvent.type(atMin.field, '0');
    expect(atMin.committed()).toBe('1:1');
    expect(atMin.field).toHaveValue(1);
  });

  it('F4: the per-line maximum of 20 applies when the stock is larger', async () => {
    const { field, committed } = renderOneLine({ stock: 500, quantity: 2 });

    await userEvent.clear(field);
    await userEvent.type(field, '45');

    expect(committed()).toBe('1:20');
  });

  it('F5: typing 0 clamps to 1 and keeps the line', async () => {
    const { field, committed, name } = renderOneLine({ quantity: 4 });

    await userEvent.clear(field);
    await userEvent.type(field, '0');

    expect(committed()).toBe('1:1');
    expect(screen.getByText(name)).toBeInTheDocument();
  });

  it('F6: a fractional value is not committed, and leaving the field restores the last good value', async () => {
    const { field, committed } = renderOneLine({ quantity: 2 });

    // Pasting "1.5" in one go avoids the intermediate "1" that typing character by character would commit.
    await userEvent.clear(field);
    await userEvent.paste('1.5');
    expect(committed()).toBe('1:2');
    expect(screen.getByText('Enter a whole number')).toBeVisible();

    await userEvent.tab(); // leave the field
    expect(field).toHaveValue(2);
    expect(committed()).toBe('1:2');
  });

  it('F7: leaving an empty field restores the committed value', async () => {
    const { field, committed } = renderOneLine({ quantity: 3 });

    await userEvent.clear(field);
    await userEvent.tab();

    expect(field).toHaveValue(3);
    expect(committed()).toBe('1:3');
  });

  it('F8: only the Remove button removes a line', async () => {
    const tee = product({ id: 1, name: 'Nest Tee' });
    const cap = product({ id: 2, name: 'Nest Cap', sku: 'nest-cap' });
    render(
      <CartHarness
        initialLines={[
          { product: tee, quantity: 1 },
          { product: cap, quantity: 1 },
        ]}
      />,
    );

    // Editing a quantity never removes its line, even when the box is emptied.
    await userEvent.clear(screen.getByLabelText('Quantity for Nest Tee'));
    expect(screen.getByText('Nest Tee')).toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Remove Nest Tee' }));

    expect(screen.queryByText('Nest Tee')).not.toBeInTheDocument();
    expect(screen.getByText('Nest Cap')).toBeInTheDocument();
    expect(screen.getByTestId('committed').textContent).toBe('2:1');
  });

  it('F12: the line and the total use the currency that came with the product', () => {
    const usdProduct = product({ price: { amountMinor: 123456, currency: 'USD' } });
    render(<CartHarness initialLines={[{ product: usdProduct, quantity: 1 }]} />);

    expect(screen.getByText('$1,234.56')).toBeInTheDocument(); // the line price
    expect(screen.getByText('Total: $1,234.56')).toBeInTheDocument();
    expect(screen.queryByText(/BDT/)).not.toBeInTheDocument();
  });
});
