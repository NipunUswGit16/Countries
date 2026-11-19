export interface Country {
  id: string;
  countryId: string;
  name: string;
  etag: string;
  createdAt: string;
  updatedAt: string;
}

export interface CreateCountryData {
  countryId: string;
  name: string;
}

export interface UpdateCountryData {
  countryId: string;
  name: string;
}

export type Paginated<T> = {
  data: T;
  pagination: {
    page: number;
    limit: number;
    total: number;
  };
};