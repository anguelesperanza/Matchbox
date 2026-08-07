# Improvements

This file lists improvents I can make to Matchbox that I discovered while trying to create things.
These things might not have been finished and that's fine, what matters is that I discovered these
areas of improvement while trying to create them.

---

# Not Started

## Remove / Reduce AI Code

While I wrote a chunk of this, so did Claude. I'd like to
reduce the AI code as I make breaking api changes,
optimazations, etc

## Reduce System Usage

Basic Init Window example uses about 53mb of ram.
Need to compare to other frameworks to see if that's a lot?

## Removing mbi

`mbi` is a main scoped struct that contains everything Matchbox needs to run effectively.
While added originally to make everything explicit and clear, having to type `&mbi` everywhere
is starting to hurt. Need to look into making the struct itself global and calling that where `mbi`
is needed as a procedure argument instead of passing it.

## Procedure Groups

`destroy` procedure group so individual procedures do not need to be called

---

# Completed
