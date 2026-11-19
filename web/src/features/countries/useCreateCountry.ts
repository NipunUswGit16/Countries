import {
  useMutation,
  useQueryClient,
  type UseMutationResult,
} from '@tanstack/react-query';
import { type Response } from '@ifs-kairos/api';
import { post } from '@ifs-kairos/net/rest';
import { useApiBaseUrl } from '@ifs-kairos/react/api';
import { type Country, type CreateCountryData } from './country.types';

export function useCreateCountry(): UseMutationResult<
  Country,
  Error,
  CreateCountryData
> {
  const apiBaseUrl = useApiBaseUrl();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: async (data: CreateCountryData) => {
      const response = await post<Response<Country>>(
        `${apiBaseUrl}/countries`,
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