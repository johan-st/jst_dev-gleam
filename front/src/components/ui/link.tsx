/**
 * TODO: Update this component to use your client-side framework's link
 * component. We've provided examples of how to do this for Next.js, Remix, and
 * Inertia.js in the Catalyst documentation:
 *
 * https://catalyst.tailwindui.com/docs#client-side-router-integration
 */

import { Link as TanLink } from '@tanstack/react-router'
import * as Headless from '@headlessui/react'
import React, { forwardRef } from 'react'
import type { LinkComponentProps } from '@tanstack/react-router'

export const Link = forwardRef(function Link(
  props: LinkComponentProps & React.ComponentPropsWithoutRef<'a'>,
  ref: React.ForwardedRef<HTMLAnchorElement>,
) {
  return (
    <Headless.DataInteractive>
      <TanLink {...props} ref={ref} />
    </Headless.DataInteractive>
  )
})
