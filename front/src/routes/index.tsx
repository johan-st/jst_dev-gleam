import { createFileRoute } from '@tanstack/react-router'
import { Text } from '../components/ui/text'

export const Route = createFileRoute('/')({
  component: RouteComponent,
})

function RouteComponent() {
  return (
    <div>
      <Text>Hello "/"!</Text>
    </div>
  )
}
