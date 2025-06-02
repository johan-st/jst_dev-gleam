import { createFileRoute, useNavigate } from '@tanstack/react-router'
import {
  Alert,
  AlertActions,
  AlertBody,
  AlertDescription,
  AlertTitle,
} from '@/components/ui/alert'
import { Button } from '@/components/ui/button'

export const Route = createFileRoute('/about')({
  component: RouteComponent,
})

function RouteComponent() {
  const navigate = useNavigate()

  return (
    <div>
      <Alert open={true} onClose={console.log}>
        <AlertTitle>not implemented</AlertTitle>
        <AlertDescription>This page is not implemented yet.</AlertDescription>
        <AlertBody>
          <AlertActions>
            <Button onClick={() => navigate({ to: '/' })}>Back to home</Button>
          </AlertActions>
        </AlertBody>
      </Alert>
    </div>
  )
}
