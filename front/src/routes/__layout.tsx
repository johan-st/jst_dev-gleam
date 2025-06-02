import { createFileRoute } from '@tanstack/react-router'

export const Route = createFileRoute('/__layout')({
  component: RouteComponent,
})

function RouteComponent() {
  return <div>Hello "/__layout"!</div>
}
    