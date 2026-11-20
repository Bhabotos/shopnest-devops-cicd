import { z } from 'zod';

// PostgreSQL `integer` (int4) upper bound. Ids beyond it would fail inside the database.
export const INT4_MAX = 2147483647;

const positiveInt4 = z.number().int().min(1).max(INT4_MAX);

export const orderSchema = z.object({
  customer: z.object({
    name: z.string().trim().min(1).max(100),
    email: z.email().max(254),
    address: z.string().trim().min(5).max(300),
  }),
  items: z
    .array(
      z.object({
        productId: positiveInt4,
        quantity: z.number().int().min(1).max(20),
      }),
    )
    .min(1)
    .max(50),
});

// Path ids: plain decimal digits only (no "1e2", "0x10" or padded values), then range-checked.
export const idSchema = z
  .string()
  .regex(/^\d{1,10}$/, 'must be a positive integer')
  .transform(Number)
  .pipe(positiveInt4);

export const uuidSchema = z.uuid();
