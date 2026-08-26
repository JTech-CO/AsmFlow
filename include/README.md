# Public assembly includes

This directory will contain stable NASM include files shared by more than one runtime binary. Do not place a
definition here preemptively. Each exported macro or structure must document ABI, size, alignment, ownership,
versioning, and consumers.
