import {
  useMutation,
  useQueryClient,
  type UseMutationResult,
} from '@tanstack/react-query';
import { delete as del } from '@ifs-kairos/net/rest';
import { useApiBaseUrl } from '@ifs-kairos/react/api';

export function useDeleteCountry(): UseMutationResult<
  void,
  Error,
  string
> {
  const apiBaseUrl = useApiBaseUrl();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (id: string) => {
      await del(`${apiBaseUrl}/countries/${id}`).execute();
    },

    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ['countries'],
      });
    },
  });
}