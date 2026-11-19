import {
  useMutation,
  useQueryClient,
  type UseMutationResult,
} from '@tanstack/react-query';
import { type Response } from '@ifs-kairos/api';
import { put } from '@ifs-kairos/net/rest';
import { useApiBaseUrl } from '@ifs-kairos/react/api';
import { type Country, type UpdateCountryData } from './country.types';

interface UpdateCountryParams {
  id: string;
  data: UpdateCountryData;
}

export function useUpdateCountry(): UseMutationResult<
  Country,
  Error,
  UpdateCountryParams
> {
  const apiBaseUrl = useApiBaseUrl();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async ({ id, data }: UpdateCountryParams) => {
      const response = await put<Response<Country>>(
        `${apiBaseUrl}/countries/${id}`,
        {
          ...data,
        }
      ).execute();

      return response.data;
    },

    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: ['countries'],
      });
    },
  });
}