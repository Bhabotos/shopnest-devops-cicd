import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import App from '../src/App.jsx';
import { validateCustomer } from '../src/components/CheckoutForm.jsx';

vi.mock('../src/api.js', () => ({
  fetchProducts: vi.fn(),
  placeOrder: vi.fn(),
}));
const api = await import('../src/api.js');

const products = [
  {
    id: 1,
    sku: 'nest-tee',
    name: 'Nest Tee',
    description: 'Soft tee.',
    price: { amountMinor: 79900, currency: 'BDT' },
    imageUrl: '/images/nest-tee.svg',
    stock: 5,
  },
  {
    id: 2,
    sku: 'nest-cap',
    name: 'Nest Cap',
    description: 'Canvas cap.',
    price: { amountMinor: 49900, currency: 'BDT' },
    imageUrl: '/images/nest-cap.svg',
    stock: 0,
  },
];

beforeEach(() => {
  vi.clearAllMocks();
  api.fetchProducts.mockResolvedValue(products);
});

describe('catalog', () => {
  it('shows a loading state and then the products', async () => {
    render(<App />);
    expect(screen.getByText('Loading products...')).toBeInTheDocument();
    expect(await screen.findByText('Nest Tee')).toBeInTheDocument();
    expect(screen.getByText(/799\.00/)).toBeInTheDocument();
  });

  it('marks out-of-stock products and offers no add button for them', async () => {
    render(<App />);
    await screen.findByText('Nest Cap');
    expect(screen.getByText('Out of stock')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /Add Nest Cap/ })).not.toBeInTheDocument();
  });

  it('shows an error with a working retry when loading fails', async () => {
    api.fetchProducts.mockRejectedValueOnce(new Error('down'));
    render(<App />);
    expect(await screen.findByText('We could not load products.')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Retry' }));
    expect(await screen.findByText('Nest Tee')).toBeInTheDocument();
  });
});

describe('cart and checkout flow', () => {
  async function addTeeAndOpenCart() {
    render(<App />);
    await userEvent.click(await screen.findByRole('button', { name: /Add Nest Tee/ }));
    await userEvent.click(screen.getByRole('button', { name: /Cart \(1\)/ }));
  }

  it('updates the cart count and shows the total', async () => {
    await addTeeAndOpenCart();
    expect(screen.getByText(/Total:.*799\.00/)).toBeInTheDocument();
  });

  it('shows an empty-cart message after removing the last item', async () => {
    await addTeeAndOpenCart();
    await userEvent.click(screen.getByRole('button', { name: /Remove Nest Tee/ }));
    expect(screen.getByText('Your cart is empty.')).toBeInTheDocument();
  });

  it('blocks submission and shows errors for invalid customer details', async () => {
    await addTeeAndOpenCart();
    await userEvent.click(screen.getByRole('button', { name: 'Proceed to checkout' }));
    await userEvent.click(screen.getByRole('button', { name: 'Place order' }));
    expect(screen.getByText('Name is required')).toBeInTheDocument();
    expect(screen.getByText('Enter a valid email address')).toBeInTheDocument();
    expect(api.placeOrder).not.toHaveBeenCalled();
  });

  it('places an order, clears the cart and shows the confirmation', async () => {
    api.placeOrder.mockResolvedValue({ id: 'order-123', total: { amountMinor: 79900, currency: 'BDT' } });
    await addTeeAndOpenCart();
    await userEvent.click(screen.getByRole('button', { name: 'Proceed to checkout' }));
    await userEvent.type(screen.getByLabelText('Name'), 'Rahim');
    await userEvent.type(screen.getByLabelText('Email'), 'rahim@example.com');
    await userEvent.type(screen.getByLabelText('Shipping address'), '12 Lake Road, Dhaka');
    await userEvent.click(screen.getByRole('button', { name: 'Place order' }));

    expect(await screen.findByText('order-123')).toBeInTheDocument();
    expect(api.placeOrder).toHaveBeenCalledWith({
      customer: { name: 'Rahim', email: 'rahim@example.com', address: '12 Lake Road, Dhaka' },
      items: [{ productId: 1, quantity: 1 }],
    });
    expect(screen.getByRole('button', { name: /Cart \(0\)/ })).toBeInTheDocument();
  });

  it('keeps the cart and shows the server message when the order fails', async () => {
    api.placeOrder.mockRejectedValue(new Error('Not enough stock for Nest Tee'));
    await addTeeAndOpenCart();
    await userEvent.click(screen.getByRole('button', { name: 'Proceed to checkout' }));
    await userEvent.type(screen.getByLabelText('Name'), 'Rahim');
    await userEvent.type(screen.getByLabelText('Email'), 'rahim@example.com');
    await userEvent.type(screen.getByLabelText('Shipping address'), '12 Lake Road, Dhaka');
    await userEvent.click(screen.getByRole('button', { name: 'Place order' }));

    await waitFor(() => expect(screen.getByText('Not enough stock for Nest Tee')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: 'Place order' })).toBeEnabled();
  });
});

describe('validateCustomer', () => {
  it('returns no errors for valid details', () => {
    expect(validateCustomer({ name: 'A', email: 'a@b.co', address: '12345' })).toEqual({});
  });

  it('flags a short address', () => {
    expect(validateCustomer({ name: 'A', email: 'a@b.co', address: '1' }).address).toBeDefined();
  });
});
