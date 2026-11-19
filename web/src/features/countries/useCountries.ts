import { useQuery, type UseQueryResult } from '@tanstack/react-query';
import { type Response } from '@ifs-kairos/api';
import { get } from '@ifs-kairos/net/rest';
import { useApiBaseUrl } from '@ifs-kairos/react/api';
import { type Country, type Paginated } from './country.types';

export interface UseCountriesOptions {
  page?: number;
  limit?: number;
}

export function useCountries(
  options: UseCountriesOptions = {}
): UseQueryResult<Paginated<Country[]>, Error> {
  const apiBaseUrl = useApiBaseUrl();
  const { page = 1, limit = 50 } = options;

  return useQuery({
    queryKey: ['countries', { page, limit }],
    queryFn: async (): Promise<Paginated<Country[]>> => {
      const response = await get<Response<Paginated<Country[]>>>(
        `${apiBaseUrl}/countries`
      )
        .addParameters({ page, limit })
        .execute();

      return response.data;
    },
  });
}